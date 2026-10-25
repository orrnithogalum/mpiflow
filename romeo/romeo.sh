#!/bin/bash
# romeo.sh -- missions 3 et 4 sur le supercalculateur ROMEO (URCA), pilotées depuis votre poste
# par votre accès SSH. Rien n'est installé sur ROMEO en dehors de votre compte.
#
#   bash romeo/romeo.sh check      connexion, Slurm (projets, partitions, types de nœuds),
#                                  Spack partagé ; écrit romeo/romeo.env et logs/romeo/check.txt
#   bash romeo/romeo.sh evidence   copie le dépôt, crée l'environnement Spack dédié, rejoue les
#                                  scénarios Slurm, rapatrie logs/romeo/ (~15 min hors attente)
#   bash romeo/romeo.sh ssh        shell sur ROMEO dans la copie du dépôt
#   bash romeo/romeo.sh clean      supprime sur ROMEO les copies faites par le CI (~/mpiflow-ci)
#
# Réglages : romeo/romeo.env (créé par « check », modifiable à la main) :
#   ROMEO_HOST         hôte SSH : alias de ~/.ssh/config ou login@machine (défaut : romeo)
#   ROMEO_DIR          copie du dépôt sur ROMEO, relative au home (défaut : mpiflow)
#   ROMEO_ENV          commande qui donne accès à Spack (défaut : romeo_load_x64cpu_env)
#   SBATCH_ACCOUNT, SBATCH_PARTITION, SBATCH_CONSTRAINT, SBATCH_QOS   lus par sbatch
# shellcheck disable=SC2029   # ROMEO_DIR est volontairement développé côté poste
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=romeo/romeo.env
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"
ROMEO_HOST=${ROMEO_HOST:-romeo}
ROMEO_DIR=${ROMEO_DIR:-mpiflow}
ROMEO_ENV=${ROMEO_ENV:-romeo_load_x64cpu_env}
VARS="ROMEO_ENV SBATCH_ACCOUNT SBATCH_PARTITION SBATCH_CONSTRAINT SBATCH_QOS MPI_LAUNCHER"
export COPYFILE_DISABLE=1                 # macOS : pas de fichiers ._* dans les archives tar

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
exports() {  # réglages non vides, sous forme de lignes export pour un script distant
    local v
    for v in $VARS; do [ -n "${!v:-}" ] && printf 'export %s=%q\n' "$v" "${!v}"; done
    return 0
}
run_remote() {  # run_remote <script> : script bash (shell de connexion) exécuté dans la copie du dépôt
    # (le script arrive sur l'entrée standard : les commandes qui lisent stdin reçoivent < /dev/null)
    { exports; echo "cd ~/$ROMEO_DIR 2> /dev/null || true"; printf '%s\n' "$1"; } \
        | ssh -o ServerAliveInterval=30 "$ROMEO_HOST" 'bash -l -s'
}
push_repo() {
    git ls-files -z | tar --null -T - -cz \
        | ssh -o ServerAliveInterval=30 "$ROMEO_HOST" "mkdir -p ~/$ROMEO_DIR && tar -xzm -C ~/$ROMEO_DIR"
}

case "${1:-}" in
check)
    say "Connexion à $ROMEO_HOST"
    if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$ROMEO_HOST" true 2> /dev/null; then
        cat <<EOF
Connexion SSH non interactive impossible vers « $ROMEO_HOST ». Les scripts et le runner
ouvrent de nombreuses connexions : il faut une clé (ssh-copy-id) ou une connexion maîtresse.
Exemple pour ~/.ssh/config (adapter HostName et User) :

  Host romeo
      HostName romeo1.univ-reims.fr
      User votre_login
      ControlMaster auto
      ControlPath ~/.ssh/cm-%r@%h:%p
      ControlPersist 8h

puis « ssh romeo » une fois (mot de passe ou double authentification), et relancer.
Autre nom d'hôte : ROMEO_HOST=login@machine bash romeo/romeo.sh check
EOF
        exit 1
    fi
    mkdir -p logs/romeo
    run_remote "$(cat <<'EOF'
echo "\$ hostname ; système ; version de Slurm"
hostname; grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"'; sinfo --version
echo "\$ sinfo -s"
sinfo -s
echo "\$ sinfo -o '%P %l %D %f'   # partition, durée maximale, nœuds, types de nœuds"
sinfo -h -o '%P %l %D %f' | sort -u
echo "\$ sacctmgr show assoc user=\$USER format=account,partition,qos"
sacctmgr -nP show assoc user="$USER" format=account,partition,qos 2> /dev/null | sort -u
echo "\$ srun --mpi=list"
srun --mpi=list < /dev/null 2>&1 | tail -n 8
_i=${ROMEO_ENV%% *}
if type "$_i" > /dev/null 2>&1; then
    echo "\$ $ROMEO_ENV ; spack --version ; spack arch ; spack compilers"
    eval "$ROMEO_ENV" > /dev/null 2>&1
else
    echo "(commande « $_i » introuvable : régler ROMEO_ENV)"
fi
if command -v spack > /dev/null; then
    spack --version; spack arch; spack compilers 2>&1 | tail -n 6
    echo "\$ spack find -v openmpi cmake"
    spack find -v openmpi cmake 2>&1 | cut -c1-120 | tail -n 12
else
    echo "spack introuvable"
fi
EOF
)" 2>&1 | tee logs/romeo/check.txt

    # choix par défaut : premier projet, partition courte, nœuds x86 (modifiable dans romeo.env)
    acc=$(sed -n '/sacctmgr show/,/srun --mpi/p' logs/romeo/check.txt | grep '|' | cut -d'|' -f1 | grep . | sort -u | head -1 || true)
    parts=$(sed -n '/sinfo -o/,/sacctmgr show/p' logs/romeo/check.txt | grep -v '^\$' | awk '{print $1}')
    part=""
    for p in debug short instant test court; do
        part=$(grep -ix -m1 "$p\*\{0,1\}" <<< "$parts" | tr -d '*' || true)
        [ -n "$part" ] && break
    done
    [ -n "$part" ] || part=$(grep -m1 '\*' <<< "$parts" | tr -d '*' || true)
    feat=$(sed -n '/sinfo -o/,/sacctmgr show/p' logs/romeo/check.txt | grep -o -m1 'x64cpu' || true)
    SBATCH_ACCOUNT=${SBATCH_ACCOUNT:-$acc}
    SBATCH_PARTITION=${SBATCH_PARTITION:-$part}
    SBATCH_CONSTRAINT=${SBATCH_CONSTRAINT:-$feat}
    cat > "$CONF" <<EOF
# Réglages ROMEO (écrits par romeo/romeo.sh check ; à corriger au besoin, puis relancer check)
ROMEO_HOST=$ROMEO_HOST
ROMEO_DIR=$ROMEO_DIR
ROMEO_ENV=$(printf '%q' "$ROMEO_ENV")
SBATCH_ACCOUNT=${SBATCH_ACCOUNT}
SBATCH_PARTITION=${SBATCH_PARTITION}
SBATCH_CONSTRAINT=${SBATCH_CONSTRAINT}
SBATCH_QOS=${SBATCH_QOS:-}
MPI_LAUNCHER=${MPI_LAUNCHER:-}
EOF
    say "Réglages retenus ($CONF)"
    grep -v '^#' "$CONF"
    if command -v gh > /dev/null && gh auth status > /dev/null 2>&1 && gh repo view > /dev/null 2>&1; then
        for v in ROMEO_HOST $VARS; do
            if [ -n "${!v:-}" ]; then
                gh variable set "$v" --body "${!v}" > /dev/null
            else
                gh variable delete "$v" > /dev/null 2>&1 || true
            fi
        done
        echo "variables du dépôt GitHub mises à jour (lues par le job test_slurm)"
    fi
    [ -n "$SBATCH_ACCOUNT" ] || echo "attention : aucun projet détecté, renseigner SBATCH_ACCOUNT dans $CONF"
    [ -n "$SBATCH_PARTITION" ] || echo "attention : aucune partition retenue, renseigner SBATCH_PARTITION dans $CONF"
    ;;

evidence)
    [ -f "$CONF" ] || { echo "Lancer d'abord : bash romeo/romeo.sh check"; exit 1; }
    say "Copie du dépôt dans ~/$ROMEO_DIR sur $ROMEO_HOST"
    push_repo
    say "Mission 4 : environnement Spack dédié (spack/romeo)"
    run_remote "bash -l romeo/evidence.sh spack < /dev/null"
    say "Mission 3 : scénarios Slurm (l'attente en file dépend de la charge de ROMEO)"
    run_remote "bash -l romeo/evidence.sh slurm < /dev/null && bash -l romeo/evidence.sh finish < /dev/null"
    say "Rapatriement de logs/romeo/ et de spack/romeo/"
    ssh "$ROMEO_HOST" "cd ~/$ROMEO_DIR && tar -cz --exclude='*.log' --exclude=.spack-env logs/romeo spack/romeo" | tar -xzm
    if [ -s logs/romeo/launcher.txt ]; then
        sed -i.bak "s/^MPI_LAUNCHER=.*/MPI_LAUNCHER=$(cat logs/romeo/launcher.txt)/" "$CONF" && rm -f "$CONF.bak"
        if command -v gh > /dev/null; then
            gh variable set MPI_LAUNCHER --body "$(cat logs/romeo/launcher.txt)" > /dev/null || true
        fi
    fi
    python3 scripts/figures.py
    git status --short logs/romeo spack
    ;;

ssh)
    ssh -t "$ROMEO_HOST" "cd ~/$ROMEO_DIR 2> /dev/null; exec bash -l"
    ;;

clean)
    ssh "$ROMEO_HOST" "rm -rf ~/mpiflow-ci && echo 'copies du CI supprimées (~/mpiflow-ci)'"
    ;;

*)
    sed -n '2,17p' "$0"
    exit 2
    ;;
esac

#!/bin/bash
# gcp.sh -- mini-cluster Slurm de deux VM GCP pour les missions 3 et 4, piloté depuis
# votre poste (ou Cloud Shell), à la racine du dépôt :
#
#   bash cluster/gcp.sh create     deux VM e2-standard-2 Ubuntu 24.04 + pare-feu interne
#   bash cluster/gcp.sh setup      Slurm, munge, slurmdbd, NFS, Spack, runner GitHub (~10 min)
#   bash cluster/gcp.sh evidence   Spack depuis spack.lock (~1 h), puis scénarios Slurm (~12 min)
#   bash cluster/gcp.sh status     VM et runner
#   bash cluster/gcp.sh ssh        shell sur hpc-login (puis : sudo -iu ci)
#   bash cluster/gcp.sh destroy    supprime VM, pare-feu et runner, vérifie qu'il ne reste rien
#
# Prérequis : gcloud connecté à votre projet (gcloud auth login ; gcloud config set
# project <id>) et, pour le runner, gh connecté au dépôt créé par
# « python3 scripts/github_evidence.py init ».
# Variables facultatives : ZONE (défaut europe-west9-a, Paris), MACHINE (e2-standard-2).
set -euo pipefail
cd "$(dirname "$0")/.."
ZONE=${ZONE:-$(gcloud config get-value compute/zone 2>/dev/null || true)}
ZONE=${ZONE:-europe-west9-a}
MACHINE=${MACHINE:-e2-standard-2}
LOGIN=hpc-login
NODE=hpc-compute
RULE=mpiflow-internal
REMOTE=/shared/ci/mpiflow

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
on() {   # on <vm> <commande> : exécute une commande sur une VM (stdin transmis)
    local vm=$1; shift
    gcloud compute ssh "$vm" --zone "$ZONE" --quiet --strict-host-key-checking=no \
        --ssh-flag=-oServerAliveInterval=30 --ssh-flag=-oLogLevel=ERROR --command "$*"
}
ghrepo() {
    gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null \
        || echo "$(gh api user -q .login)/mpiflow"
}
push_repo() {   # copie des fichiers suivis du dépôt (version de travail) vers /shared/ci/mpiflow
    git ls-files -z | tar --null -T - -cz \
        | on "$LOGIN" "sudo install -d -o ci -g ci $REMOTE && sudo tar -xz --no-same-owner -C $REMOTE && sudo chown -R ci:ci $REMOTE"
}
pull_logs() {
    mkdir -p logs/cluster
    on "$LOGIN" "sudo tar -cz -C $REMOTE --exclude='*.log' logs/cluster spack/spack.yaml spack/spack.lock" | tar -xz
}

case "${1:-}" in
create)
    say "Projet $(gcloud config get-value project 2>/dev/null), zone $ZONE, $MACHINE"
    gcloud services enable compute.googleapis.com
    if ! gcloud compute firewall-rules describe "$RULE" > /dev/null 2>&1; then
        # tout le trafic entre les deux VM : slurmctld/slurmd/slurmdbd, srun, NFS, MPI (TCP)
        gcloud compute firewall-rules create "$RULE" --network=default --direction=INGRESS \
            --allow=tcp,udp,icmp --source-tags=mpiflow --target-tags=mpiflow \
            --description="mini-cluster mpiflow : trafic entre les VM"
    fi
    gcloud compute instances create "$LOGIN" "$NODE" --zone "$ZONE" --machine-type "$MACHINE" \
        --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
        --boot-disk-size=30GB --tags=mpiflow --labels=projet=mpiflow
    say "Attente de SSH"
    for vm in "$LOGIN" "$NODE"; do
        for _ in $(seq 30); do on "$vm" true 2> /dev/null && break; sleep 10; done
        on "$vm" "echo $vm prête : \$(lsb_release -ds), \$(nproc) vCPU"
    done
    ;;

setup)
    say "Clé munge commune et scripts d'installation"
    key=$(mktemp)
    head -c 1024 /dev/urandom > "$key"
    for vm in "$LOGIN" "$NODE"; do
        on "$vm" "sudo sh -c 'umask 077; cat > /tmp/munge.key'" < "$key"
        on "$vm" "cat > /tmp/node_setup.sh" < cluster/node_setup.sh
    done
    rm -f "$key"
    say "Nœud de connexion $LOGIN (contrôleur)"
    on "$LOGIN" "sudo bash /tmp/node_setup.sh controller $LOGIN $NODE"
    say "Nœud de calcul $NODE"
    on "$NODE" "sudo bash /tmp/node_setup.sh compute $LOGIN $NODE"
    say "Copie du dépôt dans $REMOTE et vérification"
    push_repo
    if ! on "$LOGIN" "sudo -u ci bash -lc 'sleep 5; sinfo -N -o \"%N %c %m %T\"; timeout 60 srun -N2 -l hostname | sort'"; then
        echo "srun sur deux nœuds a échoué : voir /var/log/slurm/*.log sur les deux VM (bash cluster/gcp.sh ssh)."
        exit 1
    fi
    if command -v gh > /dev/null && gh auth status > /dev/null 2>&1; then
        R=$(ghrepo)
        say "Runner GitHub auto-hébergé pour $R"
        VER=$(gh api repos/actions/runner/releases/latest -q .tag_name)
        gh api -X POST "repos/$R/actions/runners/registration-token" -q .token \
            | on "$LOGIN" "sudo bash $REMOTE/cluster/runner_setup.sh https://github.com/$R ${VER#v}"
        gh variable set HPC_ENABLED --body true --repo "$R"
        sleep 5
        gh api "repos/$R/actions/runners" -q '.runners[] | "runner \(.name) : \(.status), étiquettes \([.labels[].name] | join(","))"'
    else
        echo "gh absent ou non connecté : runner non installé (relancer setup après gh auth login)"
    fi
    ;;

evidence)
    push_repo
    say "Mission 4 : installation de l'environnement Spack depuis spack.lock (environ 1 h)"
    # relançable : si la connexion coupe, « evidence » reprend le suivi sans réinstaller
    on "$LOGIN" "sudo bash $REMOTE/cluster/evidence.sh spack-bg"
    t0=$(date +%s)
    until on "$LOGIN" "grep -q '^\[code retour' $REMOTE/logs/cluster/m4-find.txt 2>/dev/null"; do
        n=$(on "$LOGIN" "grep -c '^\[+\]' $REMOTE/logs/cluster/m4-install.log 2>/dev/null; true" || true)
        printf '  %3d min : %s paquets installés sur 49\n' $(( ($(date +%s) - t0) / 60 )) "${n:-0}"
        sleep 60
    done
    on "$LOGIN" "tail -n 4 $REMOTE/logs/cluster/m4-install.txt; cat $REMOTE/logs/cluster/m4-hashes.txt"
    if ! on "$LOGIN" "grep -q '^\[code retour : 0\]' $REMOTE/logs/cluster/m4-install.txt"; then
        echo "L'installation Spack a échoué. Voir le journal complet :"
        echo "  bash cluster/gcp.sh ssh   puis   tail -50 $REMOTE/logs/cluster/m4-install.log"
        echo "Corriger, puis supprimer $REMOTE/logs/cluster/m4-find.txt et relancer « evidence »."
        exit 1
    fi
    say "Mission 3 : scénarios Slurm"
    on "$LOGIN" "sudo bash $REMOTE/cluster/evidence.sh slurm"
    say "Mission 3 : panne d'un nœud (slurmd tué sur $NODE pendant un job)"
    on "$LOGIN" "sudo bash $REMOTE/cluster/evidence.sh nodefail-start"
    sleep 15
    on "$NODE" "sudo pkill -9 -x slurmd"
    on "$LOGIN" "sudo bash $REMOTE/cluster/evidence.sh nodefail-end"
    on "$NODE" "sudo systemctl start slurmd"
    on "$LOGIN" "sleep 10; sinfo -N"
    on "$LOGIN" "sudo bash $REMOTE/cluster/evidence.sh finish"
    say "Rapatriement de logs/cluster/"
    pull_logs
    if [ -s logs/cluster/launcher.txt ] && command -v gh > /dev/null; then
        gh variable set MPI_LAUNCHER --body "$(cat logs/cluster/launcher.txt)" --repo "$(ghrepo)"
    fi
    python3 scripts/figures.py
    git status --short logs/cluster spack
    ;;

status)
    gcloud compute instances list --filter=labels.projet=mpiflow
    if command -v gh > /dev/null; then
        gh api "repos/$(ghrepo)/actions/runners" -q '.runners[] | "runner \(.name) : \(.status)"' 2> /dev/null || true
    fi
    ;;

ssh)
    gcloud compute ssh "$LOGIN" --zone "$ZONE"
    ;;

destroy)
    if command -v gh > /dev/null && gh auth status > /dev/null 2>&1; then
        R=$(ghrepo)
        for id in $(gh api "repos/$R/actions/runners" -q '.runners[] | select(.name == "hpc-login") | .id'); do
            gh api -X DELETE "repos/$R/actions/runners/$id" && echo "runner hpc-login retiré de $R"
        done
        gh variable delete HPC_ENABLED --repo "$R" 2> /dev/null || true
        gh variable delete MPI_LAUNCHER --repo "$R" 2> /dev/null || true
    fi
    gcloud compute instances delete "$LOGIN" "$NODE" --zone "$ZONE" --quiet || true
    gcloud compute firewall-rules delete "$RULE" --quiet || true
    mkdir -p logs/cluster
    {
        echo "\$ gcloud compute instances list      # $(date -Is)"
        gcloud compute instances list 2>&1
        echo "\$ gcloud compute disks list"
        gcloud compute disks list 2>&1
    } | tee logs/cluster/destroy.txt
    ;;

*)
    sed -n '2,16p' "$0"
    exit 2
    ;;
esac

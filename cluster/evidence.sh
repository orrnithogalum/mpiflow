#!/bin/bash
# evidence.sh -- preuves des missions 3 et 4 sur le mini-cluster (à lancer sur hpc-login)
#
#   sudo bash cluster/evidence.sh spack            mission 4 : Spack depuis spack.lock (~1 h)
#   sudo bash cluster/evidence.sh slurm            mission 3 : scénarios Slurm (~8 min)
#   sudo bash cluster/evidence.sh nodefail-start   mission 3 : job long, avant de tuer slurmd
#   sudo bash cluster/evidence.sh nodefail-end     ... sur hpc-compute (fait par gcp.sh)
#   sudo bash cluster/evidence.sh finish           chronologie sacct et logs/cluster/meta.tex
#
# Normalement lancé par « cluster/gcp.sh evidence ». Les commandes tournent sous
# l'utilisateur ci, dans la copie du dépôt (/shared/ci/mpiflow) ; chaque preuve est
# écrite dans logs/cluster/<nom>.txt : commande, sortie, code retour.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO/logs/cluster
SCEN=$OUT/m3-scenarios.txt
mkdir -p "$OUT"
chown ci:ci "$OUT"
SP='source ~/spack/share/spack/setup-env.sh &&'
POLL="POLL_INTERVAL=5 ./slurm/submit_and_poll.sh slurm/job_ci.sh"
if [ -s "$OUT/launcher.txt" ]; then MPI_LAUNCHER=$(cat "$OUT/launcher.txt"); export MPI_LAUNCHER; fi

as_ci() { runuser -u ci -- env ${MPI_LAUNCHER:+MPI_LAUNCHER=$MPI_LAUNCHER} bash -lc "cd '$REPO' && $1"; }
rec() {   # rec <nom> <commande> [<commande affichée>]
    local f="$OUT/$1.txt"
    { echo "\$ ${3:-$2}"; as_ci "$2" 2>&1; echo "[code retour : $?]"; } > "$f"
    chown ci:ci "$f"
    echo "-- $1 : $(tail -n 1 "$f")"
}
jobid() { cut -d';' -f1 "$REPO/.slurm_jobid"; }
scen() { echo "$(jobid)|$1" >> "$SCEN"; }

# comparaison des hash du spack.lock avec ceux des paquets installés
hashes() {
    for r in openmpi cmake; do
        lock=$(python3 -c "import json; l = json.load(open('spack/spack.lock')); \
print([x['hash'][:7] for x in l['roots'] if x['spec'].startswith('$r')][0])")
        inst=$(spack -e spack/ find --format '{hash:7}' "$r" 2>/dev/null)
        printf '%-8s spack.lock : %s   installé : %s   %s\n' "$r" "$lock" "$inst" \
            "$([ "$lock" = "$inst" ] && echo identiques || echo DIFFÉRENTS)"
    done
}

case "${1:-}" in
spack)
    rec m4-spack "$SP spack --version && spack arch && spack compiler find && spack compilers"
    # avec un spack.lock à jour, Spack ne reconcrétise pas : il installe les specs figées
    rec m4-concretize "$SP spack -e spack/ concretize"
    rec m4-install "$SP TIMEFORMAT='durée : %0lR'; time (spack -e spack/ install --fail-fast > logs/cluster/m4-install.log 2>&1; r=\$?; grep -c '^\[+\]' logs/cluster/m4-install.log | sed 's/^/paquets installés : /'; tail -n 3 logs/cluster/m4-install.log; exit \$r)" \
        "time spack -e spack/ install --fail-fast"
    rec m4-hashes "$SP $(declare -f hashes); hashes" "comparaison des hash : spack.lock / paquets installés"
    rec m4-find "$SP spack -e spack/ find -l"
    ;;

spack-bg)   # même chose, détaché de la session SSH (installation longue), une seule fois
    if grep -q '^\[code retour' "$OUT/m4-find.txt" 2> /dev/null; then
        echo "environnement Spack déjà installé"
    elif [ -s "$OUT/spack-bg.pid" ] && kill -0 "$(cat "$OUT/spack-bg.pid")" 2> /dev/null; then
        echo "installation Spack déjà en cours (pid $(cat "$OUT/spack-bg.pid"))"
    else
        nohup setsid bash "$0" spack > "$OUT/spack-bg.log" 2>&1 < /dev/null &
        echo $! > "$OUT/spack-bg.pid"
        echo "installation Spack lancée en arrière-plan (pid $!)"
    fi
    ;;

slurm)
    : > "$SCEN"
    MD=http://metadata.google.internal/computeMetadata/v1/instance
    MTYPE=$(curl -fs -H Metadata-Flavor:Google "$MD/machine-type" | awk -F/ '{print $NF}')
    ZONE=$(curl -fs -H Metadata-Flavor:Google "$MD/zone" | awk -F/ '{print $NF}')
    echo "${MTYPE:-?} ${ZONE:-?}" > "$OUT/vm.txt"
    rec cluster "echo 'deux VM ${MTYPE:-?} (zone ${ZONE:-?}), '\$(lsb_release -ds); sinfo --version; sinfo -N -o '%N %c %m %P %T'; srun --mpi=list; srun -N2 -l hostname | sort"
    rec build "bash slurm/build_hpc.sh 2>&1 | tail -n 3"

    rec m3-succes "$POLL"
    if ! grep -q '^Verdict : succès' "$OUT/m3-succes.txt"; then
        # repli : mpirun dans l'allocation (voir slurm/job_ci.sh)
        export MPI_LAUNCHER=mpirun
        rec m3-succes-mpirun "$POLL"
        if grep -q '^Verdict : succès' "$OUT/m3-succes-mpirun.txt"; then
            echo mpirun > "$OUT/launcher.txt"
        else
            unset MPI_LAUNCHER
        fi
    fi
    scen "succès"
    rec m3-wait "sbatch --wait --parsable slurm/job_ci.sh > .w1; echo \"code retour de sbatch --wait : \$?\"; tail -n 2 ci-\$(cat .w1).out; MPIFLOW_CRASH_RANK=1 sbatch --wait --parsable slurm/job_ci.sh > .w2; echo \"code retour de sbatch --wait : \$?\"; tail -n 1 ci-\$(cat .w2).out" \
        "sbatch --wait slurm/job_ci.sh ; MPIFLOW_CRASH_RANK=1 sbatch --wait slurm/job_ci.sh"
    rec m3-singleton "SRUN_MPI=none $POLL"
    rec m3-crash "MPIFLOW_CRASH_RANK=1 $POLL"
    scen "un rang plante"
    rec m3-blocage "MPIFLOW_HANG_RANK=1 $POLL --time=00:01:00"
    scen "un rang bloqué"
    rec m3-file-pleine "sbatch -J occupe-tout --nodes=2 --ntasks=4 --time=00:02:00 --wrap 'sleep 45' && $POLL"
    scen "file occupée"
    rec m3-timeout-ci "timeout 40 env $POLL --begin=now+10minutes; echo \"poller arrêté (code \$?) : timeout du job CI simulé\"; id=\$(cut -d';' -f1 .slurm_jobid); squeue -j \$id; scancel \$id; sleep 2; sacct -X -j \$id -o JobID,JobName%12,State" \
        "timeout 40 ./slurm/submit_and_poll.sh slurm/job_ci.sh --begin=now+10minutes ; scancel <job>"
    scen "attente, timeout CI"
    ;;

nodefail-start)
    f=$OUT/m3-nodefail.txt
    echo "\$ MPIFLOW_HANG_RANK=1 $POLL --time=00:05:00     # pendant le job : pkill -9 slurmd sur hpc-compute" > "$f"
    chown ci:ci "$f"
    as_ci "MPIFLOW_HANG_RANK=1 nohup setsid bash -c '$POLL --time=00:05:00; echo \"[code retour : \$?]\"' >> logs/cluster/m3-nodefail.txt 2>&1 < /dev/null &"
    for _ in $(seq 60); do
        [ -n "$(squeue -h -u ci -t R -n ci-mpiflow 2>/dev/null)" ] && break
        sleep 2
    done
    squeue -u ci
    ;;

nodefail-end)
    f=$OUT/m3-nodefail.txt
    for _ in $(seq 150); do grep -q '^\[code retour' "$f" && break; sleep 2; done
    id=$(jobid)
    {
        echo "\$ squeue; sacct -X -D -j $id -o JobID,State,Start,End      # juste après le verdict"
        squeue
        sacct -X -D -j "$id" -o JobID,State,Start,End
        echo "\$ scancel $id      # étape de nettoyage du job CI (job remis en file par Slurm)"
        scancel "$id"
    } >> "$f" 2>&1
    echo "$id|panne de nœud" >> "$SCEN"
    tail -n 8 "$f"
    ;;

finish)
    ids=$(cut -d'|' -f1 "$SCEN" | paste -sd,)
    sleep 5
    rec m3-chronologie "sacct -X -D -j $ids -o JobID,JobName%12,State,Submit,Start,End,Elapsed"
    read -r MTYPE ZONE < "$OUT/vm.txt"
    SVER=$(sinfo --version | awk '{print $2}')
    T=$(grep -o 'durée : [0-9a-z]*' "$OUT/m4-install.txt" 2>/dev/null | tail -1 | cut -d' ' -f3)
    cat > "$OUT/meta.tex" <<EOF
\\renewcommand{\\clusterinfo}{deux VM \\texttt{${MTYPE}} (zone \\texttt{${ZONE}}), Ubuntu 24.04, Slurm ${SVER}}
\\renewcommand{\\spackinstalltime}{${T:-?}}
\\renewcommand{\\mpilauncher}{$(cat "$OUT/launcher.txt" 2>/dev/null || echo srun)}
EOF
    rm -f "$REPO"/.w1 "$REPO"/.w2
    chown -R ci:ci "$OUT"
    ls "$OUT"
    ;;

*)
    sed -n '2,12p' "$0"; exit 2 ;;
esac

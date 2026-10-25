#!/bin/bash
# evidence.sh -- preuves des missions 3 et 4, exécuté SUR ROMEO dans la copie du dépôt
# (normalement par « bash romeo/romeo.sh evidence », qui transmet les réglages SBATCH_*) :
#
#   bash -l romeo/evidence.sh spack    mission 4 : environnement Spack dédié (spack/romeo)
#   bash -l romeo/evidence.sh slurm    mission 3 : scénarios Slurm, sous votre compte
#   bash -l romeo/evidence.sh finish   chronologie sacct et logs/romeo/meta.tex
#
# Chaque preuve est écrite dans logs/romeo/<nom>.txt : commande, sortie, code retour.
# Les jobs restent petits (2 nœuds, quelques minutes au plus) ; aucun droit administrateur
# n'est nécessaire : la panne de nœud est remplacée par une remise en file (scontrol requeue).
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO/logs/romeo
SCEN=$OUT/m3-scenarios.txt
mkdir -p "$OUT"
# shellcheck disable=SC2016   # développé dans le shell distant
INIT='{ eval "${ROMEO_ENV:-romeo_load_x64cpu_env}"; } > /dev/null 2>&1;'
POLL="POLL_INTERVAL=10 ./slurm/submit_and_poll.sh slurm/job_ci.sh"
if [ -s "$OUT/launcher.txt" ]; then MPI_LAUNCHER=$(cat "$OUT/launcher.txt"); export MPI_LAUNCHER; fi

rec() {   # rec <nom> <commande> [<commande affichée>]
    local f="$OUT/$1.txt"
    # tr : mpirun écrit parfois des octets NUL, qui font passer le log pour binaire
    { echo "\$ ${3:-$2}"; bash -lc "cd '$REPO' && $2" < /dev/null 2>&1; echo "[code retour : $?]"; } \
        | tr -d '\000' > "$f"
    echo "-- $1 : $(tail -n 1 "$f")"
}
jobid() { cut -d';' -f1 "$REPO/.slurm_jobid"; }
scen() { echo "$(jobid)|$1" >> "$SCEN"; }
cd "$REPO" || exit 1

case "${1:-}" in
spack)
    rec m4-romeo-spack "$INIT spack --version && spack arch && spack compilers" \
        "${ROMEO_ENV:-romeo_load_x64cpu_env} ; spack --version ; spack arch ; spack compilers"
    # réutilisation : [+] ou [^] = déjà installé (installation partagée), - = à construire
    rec m4-romeo-concretize "$INIT spack -e spack/romeo concretize --force 2>&1 | cut -c1-110" \
        "spack -e spack/romeo concretize --force"
    n_build=$(grep -c '^ - ' "$OUT/m4-romeo-concretize.txt" || true)
    n_reuse=$(grep -cE '^ ?\[(\+|\^|e)\]' "$OUT/m4-romeo-concretize.txt" || true)
    echo "$n_reuse $n_build" > "$OUT/spack-counts.txt"
    echo "   specs réutilisées : $n_reuse, à construire : $n_build"
    rec m4-romeo-install "$INIT TIMEFORMAT='durée : %0lR'; time (spack -e spack/romeo install --fail-fast > logs/romeo/m4-install.log 2>&1; r=\$?; tail -n 4 logs/romeo/m4-install.log; exit \$r)" \
        "time spack -e spack/romeo install --fail-fast"
    rec m4-romeo-find "$INIT spack -e spack/romeo find -lv 2>&1 | cut -c1-110" "spack -e spack/romeo find -lv"
    ;;

slurm)
    : > "$SCEN"
    rec cluster "hostname; grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"'; sinfo --version; env | grep '^SBATCH_' | sort; sinfo -s -p \"\${SBATCH_PARTITION:-}\" 2> /dev/null; srun --mpi=list 2>&1 | tail -n 6"
    rec build "bash -l slurm/build_hpc.sh 2>&1 | tail -n 5"

    rec m3-succes "$POLL"
    if [ -z "${MPI_LAUNCHER:-}" ] && ! grep -q '^Verdict : succès' "$OUT/m3-succes.txt"; then
        # repli : mpirun dans l'allocation (voir slurm/job_ci.sh) ; l'échec de srun est gardé
        # dans m3-srun-pmix.txt (conservé si une relance part directement de mpirun)
        mv "$OUT/m3-succes.txt" "$OUT/m3-srun-pmix.txt"
        export MPI_LAUNCHER=mpirun
        rec m3-succes "$POLL"
        if grep -q '^Verdict : succès' "$OUT/m3-succes.txt"; then
            echo mpirun > "$OUT/launcher.txt"
        else
            unset MPI_LAUNCHER
        fi
    fi
    scen "succès"
    rec m3-wait "sbatch --wait --parsable slurm/job_ci.sh > .w1; echo \"code retour de sbatch --wait : \$?\"; tail -n 2 ci-\$(cut -d';' -f1 .w1).out; MPIFLOW_CRASH_RANK=1 sbatch --wait --parsable slurm/job_ci.sh > .w2; echo \"code retour de sbatch --wait : \$?\"; tail -n 1 ci-\$(cut -d';' -f1 .w2).out" \
        "sbatch --wait slurm/job_ci.sh ; MPIFLOW_CRASH_RANK=1 sbatch --wait slurm/job_ci.sh"
    rec m3-singleton "MPI_LAUNCHER=srun SRUN_MPI=none $POLL"   # srun sans PMI, même si mpirun est retenu
    rec m3-crash "MPIFLOW_CRASH_RANK=1 $POLL"
    scen "un rang plante"
    rec m3-blocage "MPIFLOW_HANG_RANK=1 $POLL --time=00:01:00"
    scen "un rang bloqué"
    rec m3-dependance "id=\$(sbatch --parsable -J ci-avant -N1 -n1 --mem=100M --time=00:02:00 --wrap 'sleep 45'); echo \"job \${id%%;*} soumis : le job du CI l'attend\"; $POLL --dependency=afterany:\${id%%;*}" \
        "sbatch --wrap 'sleep 45' ; ./slurm/submit_and_poll.sh slurm/job_ci.sh --dependency=afterany:<job>"
    scen "attente d'un autre job"
    rec m3-timeout-ci "timeout 40 env $POLL --begin=now+10minutes; echo \"poller arrêté (code \$?) : timeout du job CI simulé\"; id=\$(cut -d';' -f1 .slurm_jobid); squeue -j \$id; scancel \$id; sleep 5; sacct -X -j \$id -o JobID,JobName%12,State" \
        "timeout 40 ./slurm/submit_and_poll.sh slurm/job_ci.sh --begin=now+10minutes ; scancel <job>"
    scen "attente, timeout CI"

    # remise en file pendant l'exécution, comme Slurm le fait après une panne de nœud
    f=$OUT/m3-requeue.txt
    echo "\$ MPIFLOW_HANG_RANK=1 $POLL --time=00:03:00 --requeue     # pendant le job : scontrol requeue <job>" > "$f"
    ( bash -lc "cd '$REPO' && MPIFLOW_HANG_RANK=1 $POLL --time=00:03:00 --requeue" < /dev/null; echo "[code retour : $?]" ) >> "$f" 2>&1 &
    pid=$!
    sleep 5
    for _ in $(seq 120); do
        [ -n "$(squeue -h -j "$(jobid)" -t R 2> /dev/null)" ] && break
        sleep 5
    done
    sleep 15
    id=$(jobid)
    scontrol requeue "$id" 2> "$OUT/requeue-err.txt" || { cat "$OUT/requeue-err.txt"; scancel "$id"; }
    wait "$pid"
    {
        echo "\$ sacct -X -D -j $id -o JobID,State,Start,End      # juste après le verdict"
        sacct -X -D -j "$id" -o JobID,State,Start,End
        echo "\$ scancel $id      # étape de nettoyage du job CI"
        scancel "$id"
    } >> "$f" 2>&1
    rm -f "$OUT/requeue-err.txt"
    echo "$id|remis en file" >> "$SCEN"
    echo "-- m3-requeue : $(grep -m1 '^\[code retour' "$f")"
    ;;

finish)
    ids=$(cut -d'|' -f1 "$SCEN" | paste -sd, -)
    sleep 5
    rec m3-chronologie "sacct -X -D -j $ids -o JobID,JobName%12,State,Submit,Start,End,Elapsed"
    read -r n_reuse n_build < "$OUT/spack-counts.txt" 2> /dev/null || { n_reuse='?'; n_build='?'; }
    T=$(grep -o 'durée : [0-9a-z]*' "$OUT/m4-romeo-install.txt" 2> /dev/null | tail -1 | cut -d' ' -f3)
    T=$(sed -E 's/^0m//; s/m/~min~/; s/s$/~s/' <<< "$T")     # 0m5s -> 5~s, 2m30s -> 2~min~30~s
    OS=$(grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    SVER=$(sinfo --version | awk '{print $2}')
    cat > "$OUT/meta.tex" <<EOF
\\renewcommand{\\romeoinfo}{${OS}, Slurm ${SVER}, partition \\texttt{${SBATCH_PARTITION:-défaut}}${SBATCH_CONSTRAINT:+, nœuds \\texttt{${SBATCH_CONSTRAINT}}}}
\\renewcommand{\\spackinstalltime}{${T:-?}}
\\renewcommand{\\spackreuse}{${n_reuse}}
\\renewcommand{\\spackbuild}{${n_build}}
\\renewcommand{\\mpilauncher}{$(cat "$OUT/launcher.txt" 2> /dev/null || echo srun)}
EOF
    rm -f "$REPO"/.w1 "$REPO"/.w2
    ls "$OUT"
    ;;

*)
    sed -n '2,11p' "$0"; exit 2 ;;
esac

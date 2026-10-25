#!/bin/bash
# ci_ssh.sh -- étapes du job test_slurm : le runner auto-hébergé (sur le poste de l'étudiant)
# pilote ROMEO par SSH, avec l'accès SSH déjà configuré sur ce poste. Aucune clé n'est stockée
# dans GitHub, et rien ne tourne en permanence sur ROMEO.
#
#   bash romeo/ci_ssh.sh sync      copie le dépôt dans ~/mpiflow-ci/<run> sur ROMEO
#   bash romeo/ci_ssh.sh run ...   compile, soumet et suit le job (slurm/ci_remote.sh)
#   bash romeo/ci_ssh.sh cancel    annule le job Slurm s'il est encore dans la file
#   bash romeo/ci_ssh.sh fetch     rapatrie ci-*.out et sacct-*.txt pour les artefacts
#
# Variables : ROMEO_HOST (obligatoire), SBATCH_*, ROMEO_ENV, MPI_LAUNCHER, METHODE,
# POLL_INTERVAL (variables du dépôt GitHub, posées par romeo/romeo.sh check).
set -euo pipefail
: "${ROMEO_HOST:?variable de dépôt ROMEO_HOST absente : lancer bash romeo/romeo.sh check}"
DIR="mpiflow-ci/${GITHUB_RUN_ID:-manuel}-${GITHUB_RUN_ATTEMPT:-1}"
export COPYFILE_DISABLE=1
SSH=(ssh -o BatchMode=yes -o ServerAliveInterval=30 "$ROMEO_HOST")
VARS="SBATCH_ACCOUNT SBATCH_PARTITION SBATCH_CONSTRAINT SBATCH_QOS ROMEO_ENV MPI_LAUNCHER METHODE POLL_INTERVAL GITHUB_SHA"
remote_env() {
    local v
    for v in $VARS; do [ -n "${!v:-}" ] && printf '%s=%q ' "$v" "${!v}"; done
    return 0
}

case "${1:-}" in
sync)
    tar --exclude=.git -cz . | "${SSH[@]}" "mkdir -p ~/$DIR && tar -xzm -C ~/$DIR"
    echo "dépôt copié dans ~/$DIR sur $ROMEO_HOST"
    ;;
run)
    shift
    # shellcheck disable=SC2029   # commande construite côté runner
    args=""
    [ $# -gt 0 ] && args=$(printf '%q ' "$@")
    "${SSH[@]}" "cd ~/$DIR && env $(remote_env) bash -l slurm/ci_remote.sh $args"
    ;;
cancel)
    "${SSH[@]}" "cd ~/$DIR 2> /dev/null && [ -s .slurm_jobid ] || exit 0
        id=\$(cut -d';' -f1 .slurm_jobid)
        if [ -n \"\$(squeue -h -j \$id 2> /dev/null)\" ]; then
            echo \"job \$id encore présent : scancel\"; scancel \$id
        else
            echo \"job \$id terminé, rien à annuler\"
        fi" || true
    ;;
fetch)
    "${SSH[@]}" "cd ~/$DIR && f=\$(ls ci-*.out sacct-*.txt 2> /dev/null) && tar -cz \$f" > .sorties.tgz || true
    if [ -s .sorties.tgz ]; then tar -xzf .sorties.tgz; fi
    rm -f .sorties.tgz
    ls ci-*.out sacct-*.txt 2> /dev/null || echo "aucune sortie de job à rapatrier"
    ;;
*)
    sed -n '2,12p' "$0"; exit 2 ;;
esac

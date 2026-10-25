#!/bin/bash
# ci_remote.sh -- exécuté sur le nœud de connexion par le job CI, via SSH (romeo/ci_ssh.sh) :
# compile avec le MPI du cluster, soumet le job Slurm et le suit (polling) ou l'attend (--wait).
#
#   METHODE=polling|wait  bash -l slurm/ci_remote.sh [options sbatch...]
#
# Le compte, la partition et la contrainte arrivent par SBATCH_ACCOUNT, SBATCH_PARTITION et
# SBATCH_CONSTRAINT, que sbatch lit dans l'environnement.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
bash -l slurm/build_hpc.sh || { echo "échec de la compilation sur le nœud de connexion"; exit 1; }

if [[ "${METHODE:-polling}" == wait ]]; then
    sbatch --wait --parsable "$@" slurm/job_ci.sh > .slurm_jobid
    rc=$?
    cat "ci-$(cut -d';' -f1 .slurm_jobid).out" 2> /dev/null
    exit "${rc}"
fi

# polling ; une seule relance, et seulement pour un échec d'infrastructure (code 75)
./slurm/submit_and_poll.sh slurm/job_ci.sh "$@"
rc=$?
if [[ ${rc} -eq 75 ]]; then
    echo "échec d'infrastructure (code 75) : nouvelle soumission"
    ./slurm/submit_and_poll.sh slurm/job_ci.sh "$@"
    rc=$?
fi
exit "${rc}"

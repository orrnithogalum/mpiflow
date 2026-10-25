#!/bin/bash
# ci_remote.sh -- exécuté sur le nœud de connexion par la variante SSH (test_slurm_ssh) :
# compile avec le MPI du cluster puis soumet et suit le job.
set -euo pipefail
bash slurm/build_hpc.sh
exec ./slurm/submit_and_poll.sh slurm/job_ci.sh "$@"

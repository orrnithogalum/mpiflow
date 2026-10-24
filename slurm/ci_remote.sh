#!/bin/bash
# ci_remote.sh -- exécuté sur le nœud de connexion par la variante SSH (test_slurm_ssh) :
# compile avec le MPI du cluster (environnement Spack du dépôt) puis soumet et suit le job.
set -euo pipefail
# shellcheck disable=SC1091
source "${SPACK_ROOT:-$HOME/spack}/share/spack/setup-env.sh"
spack -e spack/ install --fail-fast
spack env activate -d spack/
cmake -B build-hpc -DCMAKE_BUILD_TYPE=Release
cmake --build build-hpc -j4
exec ./slurm/submit_and_poll.sh slurm/job_ci.sh "$@"

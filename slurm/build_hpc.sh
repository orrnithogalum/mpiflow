#!/bin/bash
# build_hpc.sh -- compile le test avec le MPI du cluster (environnement Spack du dépôt).
# Utilisé sur le nœud de connexion par le job test_slurm (GitHub), le job .hpc (GitLab)
# et la variante SSH (ci_remote.sh). Le binaire arrive dans build-hpc/, sur le système
# de fichiers partagé : les nœuds de calcul l'exécutent sans copie.
set -euo pipefail
# shellcheck disable=SC1091
source "${SPACK_ROOT:-$HOME/spack}/share/spack/setup-env.sh"
# instantané si les paquets du spack.lock sont déjà dans le store partagé
spack -e spack/ install --fail-fast
spack env activate -d spack/
echo "mpicc : $(command -v mpicc) ($(mpicc --version | head -1))"
cmake -B build-hpc -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build-hpc -j"$(nproc)"

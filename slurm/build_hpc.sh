#!/bin/bash
# build_hpc.sh -- compile le test avec le MPI du cluster, sur le nœud de connexion.
# Appelé par slurm/ci_remote.sh (job CI via SSH), le job .hpc de GitLab et romeo/evidence.sh.
# Le binaire arrive dans build-hpc/, sur un système de fichiers que voient les nœuds de calcul.
set -eo pipefail
cd "$(dirname "$0")/.."
source slurm/env.sh
if [[ -n "${SPACK_ENV_DIR}" && -f "${SPACK_ENV_DIR}/spack.yaml" ]]; then
    # instantané si les paquets du spack.lock sont déjà installés (ou dans l'installation partagée)
    spack -e "${SPACK_ENV_DIR}" install --fail-fast
    spack env activate -d "${SPACK_ENV_DIR}"
fi
echo "environnement : ${ENV_SOURCE}"
echo "mpicc : $(command -v mpicc) ($(mpicc --version | head -1))"
cmake -B build-hpc -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build build-hpc -j 8

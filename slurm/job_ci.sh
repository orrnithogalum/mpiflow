#!/bin/bash
# job_ci.sh -- test MPI multi-nœuds soumis par le pipeline (Mission 3)
#
# Ressources : 2 nœuds × 2 tâches = 4 rangs MPI (VM e2-standard-2, 2 vCPU chacune).
# Sur un vrai cluster : --ntasks=8 --ntasks-per-node=4. Toute valeur #SBATCH peut être
# surchargée à la soumission (sbatch --partition=compute job_ci.sh) ; la partition
# « debug » est celle de cluster/node_setup.sh (vérifier avec sinfo).
#
#SBATCH --job-name=ci-mpiflow
#SBATCH --partition=debug
#SBATCH --nodes=2
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=2
#SBATCH --time=00:05:00
#SBATCH --output=ci-%j.out

set -uo pipefail

echo "== Job ${SLURM_JOB_ID} : ${SLURM_NNODES} nœud(s) [${SLURM_JOB_NODELIST}], ${SLURM_NTASKS} tâches"
echo "== Soumis depuis ${SLURM_SUBMIT_DIR} (commit ${GITHUB_SHA:-${CI_COMMIT_SHA:-hors CI}})"
cd "${SLURM_SUBMIT_DIR}" || exit 2

# --- 1. Environnement logiciel -------------------------------------------------
# Les deux VM n'ont pas Lmod : on active directement l'environnement Spack du dépôt
# (spack.yaml + spack.lock), installé dans /shared, partagé en NFS par les deux nœuds.
# Si un cluster fournit des modules, ils sont utilisés en priorité.
SPACK_ROOT="${SPACK_ROOT:-$HOME/spack}"
if type module >/dev/null 2>&1 && module -t avail openmpi 2>&1 | grep -q '^openmpi'; then
    module purge
    module load openmpi
    ENV_SOURCE="Lmod (module load openmpi)"
elif [[ -f "${SPACK_ROOT}/share/spack/setup-env.sh" && -f spack/spack.lock ]]; then
    # shellcheck disable=SC1091
    source "${SPACK_ROOT}/share/spack/setup-env.sh"
    spack env activate -d spack/
    ENV_SOURCE="Spack (environnement du dépôt, spack.lock)"
else
    ENV_SOURCE="système (PATH par défaut)"
fi
echo "== Environnement : ${ENV_SOURCE}"
echo "== mpicc : $(command -v mpicc || echo absent)"

# --- 2. Exécution ----------------------------------------------------------------
BIN="${MPIFLOW_BIN:-build-hpc/tests/test_mpi}"
if [[ ! -x "${BIN}" ]]; then
    echo "FAILED: binaire ${BIN} introuvable (compilé sur le nœud de connexion ?)"
    exit 2
fi

# EXPECTED_RANKS : le test échoue si MPI_COMM_WORLD n'a pas la taille demandée,
# ce qui arrive quand srun lance des « singletons » faute de support PMI.
# --kill-on-bad-exit=1 : si un rang plante, srun arrête les autres immédiatement
# (sinon ils restent bloqués dans une collective jusqu'au wall-time).
# MPI_LAUNCHER=mpirun : repli si le greffon PMIx de Slurm et le MPI de Spack ne
# s'entendent pas (mpirun démarre alors ses démons sur les nœuds alloués via srun).
export EXPECTED_RANKS="${SLURM_NTASKS}"
if [[ "${MPI_LAUNCHER:-srun}" == mpirun ]]; then
    mpirun -np "${SLURM_NTASKS}" "${BIN}"
else
    srun --mpi="${SRUN_MPI:-pmix}" --kill-on-bad-exit="${SRUN_KILL_ON_BAD_EXIT:-1}" "${BIN}"
fi
rc=$?

# --- 3. Verdict lisible par le pipeline -----------------------------------------
if [[ ${rc} -eq 0 ]]; then
    echo "SUCCESS: MPI test passed (${SLURM_NTASKS} rangs sur ${SLURM_NNODES} nœuds)"
else
    echo "FAILED: ${MPI_LAUNCHER:-srun} a renvoyé ${rc}"
fi
exit "${rc}"

#!/bin/bash -l
# job_ci.sh -- test MPI multi-nœuds soumis par le pipeline (Mission 3)
#
# 2 nœuds, 8 tâches (4 par nœud), cinq minutes. La partition « debug » du sujet n'existe pas
# partout : sur ROMEO, la partition, le projet et le type de nœud viennent des variables
# SBATCH_PARTITION, SBATCH_ACCOUNT et SBATCH_CONSTRAINT (romeo/romeo.env), que sbatch fait
# passer avant les lignes #SBATCH ci-dessous. Vérifier les partitions avec sinfo -s.
#
#SBATCH --job-name=ci-mpiflow
#SBATCH --partition=debug
#SBATCH --nodes=2
#SBATCH --ntasks=8
#SBATCH --ntasks-per-node=4
#SBATCH --time=00:05:00
#SBATCH --output=ci-%j.out

set -o pipefail      # pas de -u : les fonctions de Spack utilisent des variables non définies

echo "== Job ${SLURM_JOB_ID} : ${SLURM_NNODES} nœud(s) [${SLURM_JOB_NODELIST}], ${SLURM_NTASKS} tâches"
echo "== Soumis depuis ${SLURM_SUBMIT_DIR} (commit ${GITHUB_SHA:-${CI_COMMIT_SHA:-hors CI}})"
cd "${SLURM_SUBMIT_DIR}" || exit 2

# --- 1. Environnement logiciel -------------------------------------------------
# Sur ROMEO, pas de modules : l'installation Spack partagée tient ce rôle (slurm/env.sh).
# On y active l'environnement dédié du dépôt, avec lequel le binaire a été compilé.
source slurm/env.sh
if [[ -n "${SPACK_ENV_DIR}" && -f "${SPACK_ENV_DIR}/spack.lock" ]]; then
    spack env activate -d "${SPACK_ENV_DIR}"
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
# MPI_LAUNCHER=mpirun : repli si le lancement direct par srun (PMIx) ne fonctionne pas
# avec le MPI disponible (mpirun démarre alors ses démons sur les nœuds alloués).
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

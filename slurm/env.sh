# env.sh -- environnement logiciel du projet, sourcé par build_hpc.sh et job_ci.sh.
#
# Ordre de préférence :
#   1. ROMEO : la commande ROMEO_ENV (défaut romeo_load_x64cpu_env) donne accès à
#      l'installation Spack partagée ; on y active l'environnement dédié spack/romeo ;
#   2. modules Lmod, si un module openmpi existe ;
#   3. Spack cloné par l'utilisateur ($SPACK_ROOT), environnement spack/ du dépôt ;
#   4. système (PATH par défaut).
# Définit ENV_SOURCE (pour les logs) et SPACK_ENV_DIR (environnement Spack à activer).
# shellcheck shell=bash disable=SC2034
shopt -s expand_aliases
ENV_SOURCE="système (PATH par défaut)"
SPACK_ENV_DIR=""
_init="${ROMEO_ENV:-romeo_load_x64cpu_env}"
if type "${_init%% *}" > /dev/null 2>&1; then
    eval "$_init" > /dev/null 2>&1
    SPACK_ENV_DIR=spack/romeo
    ENV_SOURCE="ROMEO (${_init}, Spack partagé)"
elif type module > /dev/null 2>&1 && module -t avail openmpi 2>&1 | grep -q '^openmpi'; then
    module purge > /dev/null 2>&1
    module load openmpi
    ENV_SOURCE="Lmod (module load openmpi)"
elif [[ -f "${SPACK_ROOT:-$HOME/spack}/share/spack/setup-env.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SPACK_ROOT:-$HOME/spack}/share/spack/setup-env.sh"
    SPACK_ENV_DIR=spack
    ENV_SOURCE="Spack (${SPACK_ROOT:-$HOME/spack}, environnement spack/)"
fi
unset _init

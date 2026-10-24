#!/bin/bash
# gcp_evidence.sh -- produit les preuves des missions 3 et 4 sur le cluster GCP.
#
# A lancer sur le NŒUD DE CONNEXION du cluster Slurm du Cours 5, depuis la racine
# du dépôt cloné dans /home (partagé avec les nœuds de calcul) :
#
#     bash scripts/gcp_evidence.sh
#
# Option : GITLAB_RUNNER_TOKEN=glrt-...  enregistre aussi le runner « hpc-login »
# (jeton obtenu dans GitLab : Settings > CI/CD > Runners > New project runner,
#  tag hpc-login, case « Protected » cochée ; demande sudo).
#
# Écrit logs/gcp/*.txt et logs/gcp/meta.tex, lus par le rapport. Penser ensuite à
# commiter spack/spack.lock (concrétisé ici) et logs/gcp/, puis : terraform destroy.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
OUT=logs/gcp
mkdir -p "$OUT"

rec() {   # rec <fichier> <commande> : commande, sortie et code retour
    local log="$OUT/$1.txt"; shift
    { echo "\$ $*"; bash -o pipefail -c "$*" 2>&1; echo "[code retour : $?]"; } | tee -a "$log"
}
rm -f "$OUT"/*.txt

# --- 1. Le cluster ------------------------------------------------------------------
MD=http://metadata.google.internal/computeMetadata/v1/instance
MTYPE=$(curl -fs -H Metadata-Flavor:Google "$MD/machine-type" | awk -F/ '{print $NF}')
ZONE=$(curl -fs -H Metadata-Flavor:Google "$MD/zone" | awk -F/ '{print $NF}')
rec cluster "hostname; echo \"VM ${MTYPE:-?} (zone ${ZONE:-?})\"; sinfo --version; sinfo; srun --mpi=list"
PART=$(sinfo -h -o %P | grep -m1 '\*' | tr -d '*'); PART=${PART:-$(sinfo -h -o %P | head -1)}
NODECPUS=$(sinfo -h -p "$PART" -o %c | head -1)

# --- 2. Spack (mission 4) -------------------------------------------------------------
SPACK_ROOT=${SPACK_ROOT:-$HOME/spack}
[ -d "$SPACK_ROOT" ] || git clone --depth=1 -b v1.2.2 https://github.com/spack/spack.git "$SPACK_ROOT"
# shellcheck disable=SC1091
source "$SPACK_ROOT/share/spack/setup-env.sh"

# Slurm externe : version et préfixe du cluster (et non ceux du poste de reproduction)
SVER=$(sinfo --version | awk '{print $2}')
SPREFIX=$(dirname "$(dirname "$(command -v sinfo)")")
sed -i -E "s|(- spec: slurm@).*|\1${SVER}|; s|(prefix: ).*|\1${SPREFIX}|" spack/spack.yaml
# sans gfortran, Open MPI ne peut pas construire ses interfaces Fortran
if ! command -v gfortran >/dev/null; then
    sed -i -E 's|(- openmpi@5 schedulers=slurm) %gcc|\1 ~fortran %gcc|' spack/spack.yaml
fi
rec spack "spack --version; spack arch; spack compiler find; grep -A1 'spec: slurm' spack/spack.yaml; spack -e spack/ concretize --force | tail -4"
rec spack-install "TIMEFORMAT='durée : %0lR'; time spack -e spack/ install -j\$(nproc) 2>&1 | tail -12"
rec spack-find "spack -e spack/ find"
INSTALL_TIME=$(grep -o 'durée : [0-9a-z]*' "$OUT/spack-install.txt" | tail -1 | cut -d' ' -f3)

# --- 3. Slurm (mission 3) --------------------------------------------------------------
spack env activate -d spack/
rec build "cmake -B build-hpc -DCMAKE_BUILD_TYPE=Release > /dev/null && cmake --build build-hpc -j && mpicc --version | head -1"
# 2 nœuds × min(2, CPU par nœud) tâches
NT=$(( NODECPUS < 2 ? NODECPUS : 2 ))
rec test_slurm "POLL_INTERVAL=10 ./slurm/submit_and_poll.sh slurm/job_ci.sh --partition=$PART --nodes=2 --ntasks=$((2*NT)) --ntasks-per-node=$NT"

# --- 4. Runner GitLab (facultatif) ------------------------------------------------------
if [ -n "${GITLAB_RUNNER_TOKEN:-}" ]; then
    if ! command -v gitlab-runner >/dev/null; then
        if command -v apt-get >/dev/null; then
            curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash
            sudo apt-get install -y gitlab-runner
        else
            curl -fsSL https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh | sudo bash
            sudo dnf install -y gitlab-runner || sudo yum install -y gitlab-runner
        fi
    fi
    rec runner "sudo gitlab-runner register --non-interactive --url https://gitlab.com --token \"\$GITLAB_RUNNER_TOKEN\" --executor shell --description \"\$(hostname)-hpc-login\" && sudo gitlab-runner verify"
    sed -i 's/--token "[^"]*"/--token [MASQUÉ]/' "$OUT/runner.txt"
fi

cat > "$OUT/meta.tex" <<EOF
\\renewcommand{\\gcpinfo}{VM \\texttt{${MTYPE:-?}}, zone \\texttt{${ZONE:-?}}, Slurm ${SVER}, partition \\texttt{${PART}}}
\\renewcommand{\\spackinstalltime}{${INSTALL_TIME:-?}}
EOF
command -v latexmk >/dev/null && latexmk -g -silent carnet-de-bord.tex
command -v pandoc >/dev/null && python3 scripts/tex2md.py
echo
echo "Terminé. Commiter spack/spack.yaml, spack/spack.lock et logs/gcp/, recompiler le rapport,"
echo "puis détruire le cluster (terraform destroy) et vérifier la console."

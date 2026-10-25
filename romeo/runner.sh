#!/bin/bash
# runner.sh -- runner GitHub auto-hébergé sur VOTRE poste (étiquette romeo-ssh). Il exécute le
# job test_slurm, qui atteint ROMEO avec votre accès SSH : pas de clé dans GitHub, pas de
# service installé sur le nœud de connexion de ROMEO.
#
#   bash romeo/runner.sh start    télécharge, enregistre et lance le runner au premier plan
#                                 (laisser ce terminal ouvert ; Ctrl-C pour l'arrêter)
#   bash romeo/runner.sh remove   désenregistre le runner et désactive test_slurm
#
# Linux ou macOS (sous Windows : WSL). Nécessite gh connecté au dépôt.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=${RUNNER_DIR:-$HOME/.mpiflow-runner}
R=$(gh repo view --json nameWithOwner -q .nameWithOwner)
NAME="$(uname -n | cut -d. -f1)-romeo"      # pas hostname : absent de certaines distributions (Arch)

case "${1:-}" in
start)
    if [ ! -x "$DIR/config.sh" ]; then
        case "$(uname -s)" in Linux) os=linux ;; Darwin) os=osx ;; *) echo "système non pris en charge (WSL ?)"; exit 1 ;; esac
        case "$(uname -m)" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) echo "processeur non pris en charge"; exit 1 ;; esac
        ver=$(gh api repos/actions/runner/releases/latest -q .tag_name)
        ver=${ver#v}
        mkdir -p "$DIR"
        echo "téléchargement du runner $ver ($os-$arch) dans $DIR"
        curl -fsSL "https://github.com/actions/runner/releases/download/v${ver}/actions-runner-${os}-${arch}-${ver}.tar.gz" \
            | tar -xz -C "$DIR"
    fi
    if [ ! -f "$DIR/.runner" ]; then
        token=$(gh api -X POST "repos/$R/actions/runners/registration-token" -q .token)
        (cd "$DIR" && ./config.sh --unattended --url "https://github.com/$R" --token "$token" \
            --name "$NAME" --labels romeo-ssh --work _work --replace)
    fi
    # le job test_slurm n'est créé que si HPC_ENABLED vaut true (sinon il attendrait un runner)
    gh variable set HPC_ENABLED --body true --repo "$R" > /dev/null
    host=$(gh variable get ROMEO_HOST --repo "$R" 2> /dev/null || echo romeo)
    if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" true; then
        echo "attention : connexion SSH non interactive vers ROMEO impossible (voir romeo/romeo.sh check)"
    fi
    echo "runner $NAME prêt : laisser ce terminal ouvert pendant « github_evidence.py hpc »"
    cd "$DIR" && exec ./run.sh
    ;;
remove)
    gh variable delete HPC_ENABLED --repo "$R" > /dev/null 2>&1 || true
    if [ -f "$DIR/.runner" ]; then
        token=$(gh api -X POST "repos/$R/actions/runners/remove-token" -q .token)
        (cd "$DIR" && ./config.sh remove --token "$token")
    fi
    echo "runner retiré ; supprimer $DIR si vous ne vous en servez plus"
    ;;
*)
    sed -n '2,11p' "$0"; exit 2 ;;
esac

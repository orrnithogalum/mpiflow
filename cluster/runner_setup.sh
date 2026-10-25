#!/bin/bash
# runner_setup.sh -- installe le runner GitHub auto-hébergé « hpc-login » (Mission 3)
#
#   gh api -X POST repos/OWNER/REPO/actions/runners/registration-token -q .token \
#     | sudo bash runner_setup.sh https://github.com/OWNER/REPO 2.329.0
#
# Lancé par « cluster/gcp.sh setup » sur le nœud de connexion. Le jeton d'enregistrement
# (valable une heure) arrive sur l'entrée standard : il n'apparaît ni dans la ligne de
# commande ni dans les logs. Le runner tourne sous l'utilisateur ci (jamais root), comme
# service systemd, et ne fait que des connexions sortantes vers GitHub (HTTPS).
set -euo pipefail
URL=${1:?URL du dépôt GitHub}
VER=${2:?version du runner, ex. 2.329.0}
read -r TOKEN
DIR=/shared/ci/actions-runner
WORK=/shared/ci/_work           # espace de travail partagé : binaire et sorties visibles des deux nœuds

if [ ! -x "$DIR/config.sh" ]; then
    install -d -o ci -g ci "$DIR"
    curl -fsSL "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-x64-${VER}.tar.gz" \
        | runuser -u ci -- tar -xz -C "$DIR"
    "$DIR/bin/installdependencies.sh" > /dev/null || echo "installdependencies.sh a échoué : vérifier libicu (apt-get install libicu74)"
fi
cd "$DIR"
if [ -f .service ]; then                                   # relance : on réenregistre
    ./svc.sh stop > /dev/null 2>&1 || true
    ./svc.sh uninstall > /dev/null 2>&1 || true
fi
rm -f .runner .credentials .credentials_rsaparams
runuser -u ci -- ./config.sh --unattended --url "$URL" --token "$TOKEN" \
    --name hpc-login --labels hpc-login --work "$WORK" --replace
grep -q '^SPACK_ROOT=' .env 2>/dev/null || echo "SPACK_ROOT=/shared/ci/spack" >> .env
./svc.sh install ci > /dev/null
./svc.sh start > /dev/null
./svc.sh status | grep -E 'Active:' || true

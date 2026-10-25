#!/bin/bash
# finalise.sh -- dernière étape : figures, PDF, Markdown, commit, tag seance-inversee, push.
#
#   bash scripts/finalise.sh
#
# À lancer à la racine du dépôt, une fois les preuves collectées (logs/github/, logs/romeo/)
# et le runner retiré (bash romeo/runner.sh remove). Nécessite latexmk (TeX Live), pandoc et gh.
set -euo pipefail
cd "$(dirname "$0")/.."
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "Figures et extraits"
python3 scripts/figures.py
say "PDF (latexmk)"
latexmk -g -silent carnet-de-bord.tex > /dev/null || { tail -30 carnet-de-bord.log; exit 1; }
grep -E '^!|undefined' carnet-de-bord.log && exit 1
echo "carnet-de-bord.pdf : $(pdfinfo carnet-de-bord.pdf 2> /dev/null | awk '/^Pages/ {print $2}') pages"
say "Markdown (pandoc)"
python3 scripts/tex2md.py

say "Vérifications"
ok=1
for f in logs/github/m2-pr.txt logs/github/m3-ci-polling.txt logs/romeo/meta.tex spack/romeo/spack.lock; do
    [ -f "$f" ] || { echo "manquant : $f"; ok=0; }
done
if gh api "repos/{owner}/{repo}/actions/runners" -q '.runners[].name' 2> /dev/null | grep -q .; then
    echo "un runner auto-hébergé est encore enregistré : bash romeo/runner.sh remove"
    ok=0
fi
[ "$ok" = 1 ] && echo "preuves complètes, runner retiré" \
    || echo "le rapport garde sa page « Reste à faire » tant que des preuves manquent"

say "Commit, tag seance-inversee et push"
git add -A
git commit -q -m "Mission 5 : carnet de bord final (preuves GitHub et ROMEO)" || echo "rien à commiter"
git tag -f seance-inversee > /dev/null
cred=(-c credential.helper= -c 'credential.helper=!gh auth git-credential')
git "${cred[@]}" push -q origin main
git "${cred[@]}" push -q -f origin seance-inversee
url=$(gh repo view --json url -q .url 2> /dev/null || git remote get-url origin)
echo "Dépôt : $url (tag seance-inversee sur $(git rev-parse --short HEAD))"
echo "Rendu Moodle : carnet-de-bord.md (et .pdf) + URL du dépôt, ou une archive : git archive -o mpiflow.zip seance-inversee"

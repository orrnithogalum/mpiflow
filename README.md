# mpiflow

Dépôt de la séance en pédagogie inversée du **Cours 6 – DevOps pour le HPC**
(M2 CHPS, CHPS0902). Le carnet de bord est `carnet-de-bord.md` (version mise en page :
`carnet-de-bord.pdf`, source `carnet-de-bord.tex`).

| Fichier | Rôle | Mission |
|---|---|---|
| `tests/test_mpi.c`, `CMakeLists.txt`, `tests/CMakeLists.txt` | test MPI, build CMake, tests CTest | 1 |
| `.github/workflows/ci.yml` | pipeline testé : build, test, lint, package, secret, Slurm | 1, 2, 3 |
| `.gitlab-ci.yml` | équivalent GitLab, validé avec `gitlab-ci-local` | 1, 2, 3 |
| `scripts/fake_docker_login.sh` | simule `docker login --password-stdin` | 2 |
| `slurm/job_ci.sh`, `slurm/submit_and_poll.sh`, `slurm/build_hpc.sh`, `slurm/ci_remote.sh` | job Slurm, soumission et suivi, compilation sur le cluster | 3 |
| `romeo/`, `slurm/env.sh` | missions 3 et 4 sur ROMEO : réglages, preuves, runner sur votre poste, étapes SSH du CI | 3, 4 |
| `spack/`, `spack/romeo/` | environnements Spack versionnés : poste local et ROMEO | 4 |
| `scripts/github_evidence.py`, `scripts/figures.py`, `scripts/tex2md.py`, `scripts/finalise.sh` | collecte des preuves et génération du carnet | 5 |

## Utilisation locale

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
cd build && ctest --output-on-failure
```

## Rejouer les preuves (GitHub et ROMEO)

Prérequis sur votre poste (Linux ou macOS) : `git`, `gh` connecté avec le droit de pousser des
workflows (`gh auth login -s workflow`), un accès SSH à ROMEO **sans saisie** (clé, ou connexion
maîtresse `ControlMaster` ouverte une fois avec `ssh romeo`), et pour la dernière étape TeX Live
(`latexmk`) et `pandoc`.

```bash
python3 scripts/github_evidence.py init     # dépôt GitHub, secret, push de main       (~3 min)
python3 scripts/github_evidence.py demo     # needs, pull request, tags                (~15 min)
bash romeo/romeo.sh check                   # projets, partitions, Spack -> romeo/romeo.env
bash romeo/romeo.sh evidence                # Spack dédié et scénarios Slurm sur ROMEO (~15 min + file)
bash romeo/runner.sh start                  # AUTRE terminal : runner romeo-ssh sur ce poste
python3 scripts/github_evidence.py hpc      # test_slurm depuis GitHub                  (~10 min + file)
bash romeo/runner.sh remove                 # après Ctrl-C dans le terminal du runner
bash scripts/finalise.sh                    # PDF, Markdown, commit, tag seance-inversee, push
```

Chaque étape écrit ses preuves dans `logs/github/` ou `logs/romeo/` ; le rapport les inclut à la
compilation suivante et remplace les preuves locales. Rien n'est installé sur ROMEO hors de
votre compte ; `bash romeo/romeo.sh clean` supprime les copies du dépôt faites par le CI.

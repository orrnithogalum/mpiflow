# mpiflow

Dépôt de travail de la séance en pédagogie inversée du **Cours 6 – DevOps pour le HPC**
(M2 CHPS, CHPS0902 – Virtualisation et cloud pour le HPC).

| Fichier | Rôle | Mission |
|---|---|---|
| `tests/test_mpi.c` | test MPI (Bcast + Allreduce + taille du communicateur) | 1 |
| `CMakeLists.txt`, `tests/CMakeLists.txt` | build CMake, tests CTest, packaging CPack | 1, 2 |
| `.gitlab-ci.yml` | pipeline GitLab : build, test, lint (MR), package (tags), secrets, Slurm | 1, 2, 3 |
| `.github/workflows/ci.yml` | équivalent GitHub Actions | 1, 2 |
| `scripts/fake_docker_login.sh` | simule `docker login --password-stdin` | 2 |
| `slurm/job_ci.sh` | job Slurm (2 nœuds, MPI, SUCCESS) | 3 |
| `slurm/submit_and_poll.sh` | soumission `sbatch --parsable` + polling `sacct` | 3 |
| `spack/spack.yaml`, `spack/spack.lock` | environnement Spack versionné | 4 |
| `carnet-de-bord.tex`, `logs/` | compte rendu (LaTeX) et sorties brutes citées | 5 |

## Utilisation locale

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
cd build && ctest --output-on-failure
mpirun -np 4 ./tests/test_mpi
```

En conteneur CI (root, peu de cœurs) :
`-DMPIEXEC_PREFLAGS="--allow-run-as-root;--oversubscribe"`.

## Compiler le carnet de bord

```bash
latexmk -g                   # PDF (pdfLaTeX)
python3 scripts/tex2md.py    # carnet-de-bord.md (pandoc)
```

Sur Overleaf : importer le dépôt (zip) ; le compilateur par défaut (pdfLaTeX) convient.
Le rapport inclut directement les fichiers du dépôt et de `logs/` : modifier un
script ou rejouer une commande met le PDF à jour à la compilation suivante.

## Preuves GitLab.com et GCP

```bash
GITLAB_TOKEN=glpat-... python3 scripts/gitlab_evidence.py   # sur votre machine, branche main
bash scripts/gcp_evidence.sh                                 # sur le nœud de connexion GCP
```

Les logs arrivent dans `logs/gitlab/` et `logs/gcp/` ; le rapport les inclut et retire
la page « Reste à faire » dès que les deux existent.

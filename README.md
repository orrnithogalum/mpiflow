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
| `slurm/job_ci.sh`, `slurm/submit_and_poll.sh`, `slurm/build_hpc.sh` | job Slurm, soumission et suivi, compilation sur le cluster | 3 |
| `cluster/` | mini-cluster de deux VM GCP : création, configuration, preuves, destruction | 3, 4 |
| `spack/spack.yaml`, `spack/spack.lock` | environnement Spack versionné | 4 |
| `scripts/github_evidence.py`, `scripts/figures.py`, `scripts/tex2md.py`, `scripts/finalise.sh` | collecte des preuves et génération du carnet | 5 |

## Utilisation locale

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
cd build && ctest --output-on-failure
```

## Rejouer les preuves (GitHub et deux VM GCP)

Prérequis sur votre poste : `git`, `gh` connecté (`gh auth login`), `gcloud` connecté au
projet (`gcloud auth login`, `gcloud config set project <id>`), et pour la dernière étape
TeX Live (`latexmk`) et `pandoc`.

```bash
python3 scripts/github_evidence.py init     # dépôt GitHub, secret, push de main   (~3 min)
python3 scripts/github_evidence.py demo     # needs, pull request, tags            (~15 min)
bash cluster/gcp.sh create                  # deux VM e2-standard-2                (~2 min)
bash cluster/gcp.sh setup                   # Slurm, NFS, Spack, runner GitHub     (~10 min)
bash cluster/gcp.sh evidence                # Spack depuis spack.lock, scénarios   (~1 h 15)
python3 scripts/github_evidence.py hpc      # test_slurm depuis GitHub             (~10 min)
bash cluster/gcp.sh destroy                 # VM, pare-feu et runner supprimés
bash scripts/finalise.sh                    # PDF, Markdown, commit, tag seance-inversee, push
```

Chaque étape écrit ses preuves dans `logs/github/` ou `logs/cluster/` ; le rapport les inclut
à la compilation suivante et remplace les preuves locales. `bash cluster/gcp.sh status`
indique les VM actives et l'état du runner.

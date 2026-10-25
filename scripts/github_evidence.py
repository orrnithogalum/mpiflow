#!/usr/bin/env python3
"""github_evidence.py -- preuves GitHub Actions des missions 1, 2 et 3, via la CLI gh.

A lancer depuis la racine du dépôt, sur la branche main, arbre de travail propre :

    python3 scripts/github_evidence.py init [--public]   # dépôt, secret, push de main (~3 min)
    python3 scripts/github_evidence.py demo              # needs, PR + lint, tags, protection (~15 min)
    python3 scripts/github_evidence.py hpc               # test_slurm sur ROMEO (~10 min hors attente)

Prérequis : gh connecté (gh auth login -s workflow). « hpc » suppose ROMEO prêt
(romeo/romeo.sh check puis evidence) et le runner lancé dans un autre terminal
(romeo/runner.sh start). Chaque étape écrit ses preuves dans logs/github/ et met à jour
logs/github/runs.json (lu par scripts/figures.py) et logs/github/meta.tex (lu par le rapport).

Aucun jeton n'est manipulé ici : gh fournit lui-même l'authentification à git
(credential.helper « gh auth git-credential », passé en option, jamais écrit dans
.git/config). Le secret FAKE_REGISTRY_TOKEN est une fausse valeur.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

OUT = "logs/github"
FAKE = "FAUX-jeton-ci-0123456789"
WF = "ci.yml"
JOBS = ["lint", "build", "test", "registry_login", "package", "test_slurm"]
R = None                                   # owner/mpiflow
seen = set()                               # runs déjà exploités


# ---------------------------------------------------------------- outils -----
def run(cmd, check=True, input=None):
    p = subprocess.run(cmd, capture_output=True, text=True, input=input)
    if check and p.returncode:
        sys.exit(f"échec : {' '.join(cmd)}\n{(p.stderr or p.stdout).strip()}")
    return p


def gh(*args, check=True, input=None):
    return run(["gh", *args], check, input).stdout.strip()


def ghj(*args):
    out = gh(*args)
    return json.loads(out) if out else None


def git(*args, check=True):
    return run(["git", *args], check).stdout.strip()


def push(*refs, force=False):
    cred = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"]
    git(*cred, "push", *(["-f"] if force else []), "origin", *refs)


def now():
    return datetime.now(timezone.utc)


def iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def say(msg):
    print(f"\n\033[1m== {msg}\033[0m", flush=True)


def write(name, lines):
    os.makedirs(OUT, exist_ok=True)
    with open(f"{OUT}/{name}", "w", encoding="utf-8") as f:
        f.write("\n".join(lines).rstrip() + "\n")
    print(f"  -> {OUT}/{name}")


def remember(key, title, r, jobs):
    path = f"{OUT}/runs.json"
    data = json.load(open(path)) if os.path.exists(path) else {}
    data[key] = {"titre": title, "url": r["url"] if r else None,
                 "jobs": {j["name"]: j["conclusion"] or j["status"] for j in jobs}}
    os.makedirs(OUT, exist_ok=True)
    json.dump(data, open(path, "w"), indent=1, ensure_ascii=False)


# ------------------------------------------------------------- runs, jobs ----
def find_runs(since=None, **flt):
    args = ["run", "list", "--repo", R, "--workflow", WF, "-L", "30", "--json",
            "databaseId,status,conclusion,event,headBranch,headSha,url,createdAt"]
    for k, v in flt.items():
        args += [f"--{k}", v]
    runs = ghj(*args) or []
    return [r for r in runs if r["databaseId"] not in seen
            and (since is None or iso(r["createdAt"]).timestamp() >= since.timestamp() - 5)]


def wait_run(since=None, timeout=2400, **flt):
    """Attend qu'un run correspondant apparaisse puis se termine ; renvoie le plus récent."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        runs = find_runs(since, **flt)
        if runs and runs[0]["status"] == "completed":
            seen.add(runs[0]["databaseId"])
            print(f"  run {runs[0]['url']} : {runs[0]['conclusion']}")
            return runs[0]
        print(f"  ... {runs[0]['status'] if runs else 'en attente du run'}"
              f" ({int(time.time() - t0)} s)", flush=True)
        time.sleep(15)
    sys.exit(f"Aucun run terminé pour {flt} après {timeout} s")


def jobs_of(r):
    return ghj("run", "view", str(r["databaseId"]), "--repo", R, "--json", "jobs")["jobs"]


def log_of(job):
    p = run(["gh", "api", f"repos/{R}/actions/jobs/{job['databaseId']}/logs"], check=False)
    out = []
    for line in p.stdout.replace("﻿", "").splitlines():
        line = re.sub(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?", "", line)
        line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line).rstrip()
        if line.startswith("##[group]"):
            line = "> " + line[9:]
        elif line.startswith(("##[endgroup]", "shell: ", "env:")) or not line.strip():
            continue
        out.append(line.replace("##[error]", "Error: ").replace("##[warning]", "Warning: "))
    return out


def annotations(job):
    p = run(["gh", "api", f"repos/{R}/check-runs/{job['databaseId']}/annotations"], check=False)
    try:
        return [f"  [{a['annotation_level']}] {a['message']}" for a in json.loads(p.stdout or "[]")]
    except (json.JSONDecodeError, TypeError):
        return []


def table(jobs):
    by = {j["name"]: j for j in jobs}
    rows = ["  job              résultat     durée"]
    for name in JOBS + sorted(set(by) - set(JOBS)):
        j = by.get(name)
        if not j:
            continue
        a, b = iso(j.get("startedAt")), iso(j.get("completedAt"))
        d = f"{int((b - a).total_seconds())} s" if a and b and j["conclusion"] != "skipped" else "-"
        rows.append(f"  {name:<16} {j['conclusion'] or j['status']:<12} {d}")
    return rows


def grep(lines, pattern, limit=30):
    sel = [l for l in lines if re.search(pattern, l)]
    return sel[:limit]


def header(r, what):
    return [f"Run {r['url']}", f"({what}, commit {r['headSha'][:7]}) : {r['conclusion']}"]


def dispatch(ref, **inputs):
    t0 = now()
    args = ["workflow", "run", WF, "--repo", R, "--ref", ref]
    for k, v in inputs.items():
        args += ["-f", f"{k}={v}"]
    for _ in range(12):                    # le workflow peut mettre quelques s à être connu
        if run(["gh", *args], check=False).returncode == 0:
            return t0
        time.sleep(10)
    sys.exit("gh workflow run a échoué : le workflow est-il bien sur main ?")


# ------------------------------------------------------------------ étapes ----
def preflight():
    st = run(["gh", "auth", "status"], check=False)
    if st.returncode:
        sys.exit("gh n'est pas connecté : lancer « gh auth login -s workflow ».")
    scopes = re.search(r"Token scopes: (.*)", st.stdout + st.stderr)
    if scopes and "workflow" not in scopes.group(1):
        sys.exit("Le jeton de gh ne peut pas pousser de workflow : lancer « gh auth refresh -s workflow ».")
    if git("status", "--porcelain", "--untracked-files=no"):
        sys.exit("Commiter ou mettre de côté les modifications en cours avant de lancer le script.")
    if git("branch", "--show-current") != "main":
        sys.exit("Se placer sur la branche main (git checkout main).")


def init(public):
    say(f"Dépôt {R}")
    if run(["gh", "repo", "view", R, "--json", "url"], check=False).returncode:
        gh("repo", "create", R, "--public" if public else "--private",
           "--description", "M2 CHPS, CHPS0902, Cours 6 : DevOps pour le HPC (séance inversée)")
        print(f"  dépôt {'public' if public else 'privé'} créé")
    url = f"https://github.com/{R}.git"
    origin = run(["git", "remote", "get-url", "origin"], check=False).stdout.strip()
    if not origin:
        git("remote", "add", "origin", url)
    elif origin.removesuffix(".git") != url.removesuffix(".git"):
        print(f"  attention : origin pointe vers {origin} (conservé)")

    say("Secret FAKE_REGISTRY_TOKEN (fausse valeur)")
    scope = "environnement"
    policy = json.dumps({"deployment_branch_policy": {"protected_branches": False,
                                                      "custom_branch_policies": True}})
    ok = run(["gh", "api", "-X", "PUT", f"repos/{R}/environments/release", "--input", "-"],
             check=False, input=policy).returncode == 0
    if ok:
        names = gh("api", f"repos/{R}/environments/release/deployment-branch-policies",
                   "-q", ".branch_policies[].name", check=False)
        if "v*" not in names.split():
            ok = run(["gh", "api", "-X", "POST",
                      f"repos/{R}/environments/release/deployment-branch-policies",
                      "-f", "name=v*", "-f", "type=tag"], check=False).returncode == 0
    if ok:
        ok = run(["gh", "secret", "set", "FAKE_REGISTRY_TOKEN", "--env", "release", "--repo", R,
                  "--body", FAKE], check=False).returncode == 0
    if ok:
        run(["gh", "secret", "delete", "FAKE_REGISTRY_TOKEN", "--repo", R], check=False)
        print("  secret de l'environnement « release », déployable seulement depuis les tags v*")
    else:
        scope = "depot"
        gh("secret", "set", "FAKE_REGISTRY_TOKEN", "--repo", R, "--body", FAKE)
        print("  environnements protégés indisponibles (dépôt privé sur l'offre Free) :"
              " secret de dépôt (relancer avec --public pour la version protégée)")
    # sur un dépôt public : approbation obligatoire des workflows venant de forks
    # (protège le runner auto-hébergé contre du code arbitraire)
    run(["gh", "api", "-X", "PUT", f"repos/{R}/actions/permissions/fork-pr-contributor-approval",
         "-f", "approval_policy=all_external_contributors"], check=False)

    say("Mission 1 : push de main et pipeline de branche")
    sha = git("rev-parse", "HEAD")
    push("main")
    r = wait_run(commit=sha, event="push")
    js = jobs_of(r)
    remember("push-main", "push sur main", r, js)
    test = next((j for j in js if j["name"] == "test"), None)
    reg = next((j for j in js if j["name"] == "registry_login"), None)
    write("m1-main.txt", header(r, "push sur main") + table(js)
          + ["", "--- job test (extrait) ---"]
          + grep(log_of(test) if test else [], r"Test +#|tests passed|rang \d|MPI test")
          + ["", "--- job registry_login ---"]
          + grep(log_of(reg) if reg else [], r"ref=|vide|masquage|Login"))
    write("meta.tex", [r"\renewcommand{\depot}{\url{https://github.com/%s}}" % R,
                       r"\renewcommand{\ghsecret}{%s}" % scope])


def demo():
    try:
        _demo()
    finally:                                # en cas d'interruption : retour propre sur main
        run(["git", "checkout", "-q", "-f", "main"], check=False)
    regenerate()


def _demo():
    main_sha = git("rev-parse", "HEAD")

    say("Mission 1 : test sans « needs » (workflow_dispatch sur une branche de démonstration)")
    br = "demo/sans-needs"
    git("checkout", "-q", "-B", br)
    wf = open(".github/workflows/ci.yml").read()
    open(".github/workflows/ci.yml", "w").write(re.sub(r"\n    needs: build +#[^\n]*", "", wf, count=1))
    git("commit", "-q", "-am", "demo: job test sans needs")
    push(br, force=True)
    t0 = dispatch(br, hpc="false")
    r = wait_run(since=t0, event="workflow_dispatch", branch=br)
    js = jobs_of(r)
    remember("sans-needs", "test sans needs", r, js)
    test = next(j for j in js if j["name"] == "test")
    write("m1-sans-needs.txt", header(r, "workflow_dispatch, test sans needs") + table(js)
          + ["", "--- job test ---"] + grep(log_of(test), r"[Aa]rtifact|not found|Error|tar:", 12)
          + annotations(test))
    git("checkout", "-q", "main")
    git("branch", "-q", "-D", br)
    run(["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
         "push", "-q", "origin", "--delete", br], check=False)

    say("Mission 2 : pull request avec une erreur détectée par cppcheck")
    br = "demo/lint"
    git("checkout", "-q", "-B", br)
    src = open("tests/test_mpi.c").read()
    open("tests/test_mpi.c", "w").write(src.replace(
        "int errors = 0;", "int errors = 0;\n    int tab[4];\n    tab[4] = rank; /* erreur volontaire */", 1))
    git("commit", "-q", "-am", "demo: écriture hors du tableau (erreur volontaire)")
    sha1 = git("rev-parse", "HEAD")
    push(br, force=True)
    pr = run(["gh", "pr", "view", br, "--repo", R, "--json", "number,url,state"], check=False)
    pr = json.loads(pr.stdout) if pr.returncode == 0 and '"OPEN"' in pr.stdout else None
    if not pr:
        gh("pr", "create", "--repo", R, "--head", br, "--base", "main",
           "--title", "Démo lint (à ne pas fusionner)",
           "--body", "Pull request de démonstration (mission 2) : erreur volontaire détectée par cppcheck.")
        pr = ghj("pr", "view", br, "--repo", R, "--json", "number,url,state")
    r = wait_run(commit=sha1)
    time.sleep(20)                          # un éventuel second run (push) aurait eu le temps d'apparaître
    allruns = ghj("run", "list", "--repo", R, "--commit", sha1, "--json", "databaseId,event") or []
    js = jobs_of(r)
    remember("pr-lint", "pull request, erreur cppcheck", r, js)
    by = {j["name"]: j for j in js}
    write("m2-pr.txt", [f"Pull request {pr['url']}",
                        f"runs créés pour le commit {sha1[:7]} : {len(allruns)} "
                        f"({', '.join(sorted({x['event'] for x in allruns}))})"]
          + header(r, "pull_request") + table(js)
          + ["", "--- job lint ---"]
          + grep(log_of(by["lint"]) if "lint" in by else [], r"cppcheck|error|Checking|tab\[|exit code|Error")
          + ["", "--- job registry_login (pull request) ---"]
          + grep(log_of(by["registry_login"]) if "registry_login" in by else [], r"ref=|vide|masquage|Login"))

    say("Mission 1 : deux jobs indépendants en échec (lint et build)")
    src = open("tests/test_mpi.c").read()
    open("tests/test_mpi.c", "w").write(src.replace("MPI_Finalize();", "MPI_Finalize()", 1))
    git("commit", "-q", "-am", "demo: point-virgule manquant (erreur de compilation)")
    sha2 = git("rev-parse", "HEAD")
    push(br, force=True)
    r = wait_run(commit=sha2)
    js = jobs_of(r)
    remember("pr-build", "pull request, + erreur de compilation", r, js)
    build = next(j for j in js if j["name"] == "build")
    write("m1-echecs.txt", header(r, "pull_request, lint et build en échec") + table(js)
          + ["", "--- job build ---"] + grep(log_of(build), r"error:|Error:|\^", 8))
    gh("pr", "close", str(pr["number"]), "--repo", R, "--delete-branch", "--comment",
       "Démonstration terminée.")
    git("checkout", "-q", "main")
    git("branch", "-q", "-D", br)

    say("Mission 2 : tag v0.1.0 -> job package")
    git("tag", "-f", "v0.1.0", main_sha)
    push("refs/tags/v0.1.0", force=True)
    r = wait_run(branch="v0.1.0", event="push")
    js = jobs_of(r)
    remember("tag", "tag v0.1.0", r, js)
    pkg = next((j for j in js if j["name"] == "package"), None)
    arts = gh("api", f"repos/{R}/actions/runs/{r['databaseId']}/artifacts",
              "-q", '.artifacts[] | "\\(.name) : \\(.size_in_bytes) o"', check=False)
    write("m2-tag.txt", header(r, "push du tag v0.1.0") + table(js)
          + ["", "--- job package ---"]
          + grep(log_of(pkg) if pkg else [], r"mpiflow-v|sha256|masquage|Login|\.tar\.gz")
          + ["", "artefacts du run :"] + ["  " + x.strip() for x in arts.splitlines()])

    say("Mission 2 : tag v0.1.0-rc1 (hors motif vX.Y.Z)")
    git("tag", "-f", "v0.1.0-rc1", main_sha)
    t0 = now()
    push("refs/tags/v0.1.0-rc1", force=True)
    time.sleep(60)
    runs = find_runs(since=t0, branch="v0.1.0-rc1")
    remember("rc1", "tag v0.1.0-rc1", None, [])
    write("m2-rc1.txt", ["$ git push origin v0.1.0-rc1 ; (60 s plus tard) gh run list --branch v0.1.0-rc1",
                         f"runs déclenchés : {len(runs)}"]
          + [f"  {x['url']} ({x['event']})" for x in runs])
    run(["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
         "push", "-q", "origin", "--delete", "v0.1.0-rc1"], check=False)
    git("tag", "-d", "v0.1.0-rc1")

    say("Mission 2 : job package forcé depuis main (protection de l'environnement)")
    t0 = dispatch("main", hpc="false", publier="true")
    r = wait_run(since=t0, event="workflow_dispatch", branch="main")
    js = jobs_of(r)
    remember("publier", "package forcé depuis main", r, js)
    by = {j["name"]: j for j in js}
    out = header(r, "workflow_dispatch sur main, publier=true") + table(js)
    if "package" in by:
        out += ["", "--- job package ---"] + annotations(by["package"]) \
            + grep(log_of(by["package"]), r"not allowed|protection|masquage|Login|vide")
    write("m2-protection.txt", out)


def hpc():
    say("Mission 3 : runner auto-hébergé")
    runners = ghj("api", f"repos/{R}/actions/runners")["runners"]
    rn = next((x for x in runners if any(l["name"] == "romeo-ssh" for l in x["labels"])
               and x["status"] == "online"), None)
    if not rn or rn["status"] != "online":
        sys.exit("Aucun runner romeo-ssh en ligne : lancer « bash romeo/runner.sh start » dans un autre terminal.")
    print(f"  runner {rn['name']} : {rn['status']}, étiquettes "
          f"{', '.join(l['name'] for l in rn['labels'])}")

    def slurm_log(job):
        return grep(log_of(job), r"^> Run|dépôt copié|environnement :|mpicc :|Job Slurm|^\[\d\d:|début estimé|Verdict|SUCCESS|FAILED"
                    r"|passed|rang \d|COMPLETED|CANCELLED|^---- |^JobID|^\d+(\.\w+)? |encore présent"
                    r"|terminé, rien|scancel|Error|cancel", 40)

    for methode in ("polling", "wait"):
        say(f"test_slurm, suivi par {methode}")
        t0 = dispatch("main", hpc="true", methode=methode)
        r = wait_run(since=t0, event="workflow_dispatch", branch="main")
        js = jobs_of(r)
        remember(f"hpc-{methode}", f"workflow_dispatch, test_slurm ({methode})", r, js)
        ts = next(j for j in js if j["name"] == "test_slurm")
        write(f"m3-ci-{methode}.txt", header(r, f"workflow_dispatch, méthode {methode}") + table(js)
              + ["", "--- job test_slurm (runner romeo-ssh, SSH vers ROMEO) ---"] + slurm_log(ts))

    say("test_slurm annulé pendant l'attente en file (--begin=now+10minutes)")
    t0 = dispatch("main", hpc="true", sbatch_opts="--begin=now+10minutes")
    rid = None
    for _ in range(80):
        runs = find_runs(since=t0, event="workflow_dispatch", branch="main")
        if runs:
            rid = runs[0]["databaseId"]
            ts = next((j for j in jobs_of(runs[0]) if j["name"] == "test_slurm"), None)
            step = next((s for s in (ts or {}).get("steps", []) if s["name"].startswith("Soumission")), None)
            if step and step["status"] == "in_progress":
                break
        time.sleep(10)
    if rid is None:
        sys.exit("Run de démonstration de l'annulation introuvable.")
    time.sleep(45)                          # le job Slurm attend (BeginTime) : on annule le run
    gh("run", "cancel", str(rid), "--repo", R)
    r = wait_run(since=t0, event="workflow_dispatch", branch="main")
    js = jobs_of(r)
    remember("hpc-annulation", "workflow_dispatch, annulé pendant l'attente", r, js)
    ts = next(j for j in js if j["name"] == "test_slurm")
    steps = [f"  étape « {s['name']} » : {s['conclusion']}" for s in ts.get("steps", [])]
    write("m3-ci-annulation.txt", header(r, "workflow_dispatch annulé, job Slurm en attente")
          + table(js) + ["", "étapes de test_slurm :"] + steps
          + ["", "--- job test_slurm ---"] + slurm_log(ts))
    regenerate()


def regenerate():
    """Figures, PDF et Markdown si les outils sont présents."""
    run([sys.executable, "scripts/figures.py"], check=False)
    if run(["which", "latexmk"], check=False).returncode == 0:
        run(["latexmk", "-g", "-silent", "carnet-de-bord.tex"], check=False)
    if run(["which", "pandoc"], check=False).returncode == 0:
        run([sys.executable, "scripts/tex2md.py"], check=False)
    print("\nPreuves dans logs/github/ : les commiter avec le rapport (scripts/finalise.sh).")


def main():
    global R
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("etape", choices=["init", "demo", "hpc"])
    ap.add_argument("--public", action="store_true", help="dépôt public (à la création)")
    a = ap.parse_args()
    preflight()
    R = os.environ.get("MPIFLOW_REPO") or f"{gh('api', 'user', '-q', '.login')}/mpiflow"
    {"init": lambda: init(a.public), "demo": demo, "hpc": hpc}[a.etape]()


if __name__ == "__main__":
    main()

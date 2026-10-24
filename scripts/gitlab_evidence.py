#!/usr/bin/env python3
"""gitlab_evidence.py -- produit les preuves GitLab.com des missions 1 et 2.

A lancer depuis la racine du dépôt, sur votre machine :

    export GITLAB_TOKEN=glpat-...          # jeton personnel, portée « api »
    python3 scripts/gitlab_evidence.py     # projet <votre-utilisateur>/mpiflow

Le script :
  1. crée le projet privé s'il n'existe pas et déclare FAKE_REGISTRY_TOKEN
     (Masked + Protected, fausse valeur) ;
  2. pousse main et attend le pipeline de branche (mission 1, secret masqué) ;
  3. ouvre une merge request, y pousse une erreur volontaire et vérifie qu'un
     seul pipeline (de MR) est créé, avec lint en échec (mission 2) ;
  4. pose le tag v0.1.0 et attend le job package (mission 2) ;
  5. écrit les logs dans logs/gitlab/ et logs/gitlab/meta.tex, lus par le rapport.

Le jeton n'est jamais écrit dans la configuration Git ni dans les logs.
"""
import base64, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

API = os.environ.get("GITLAB_URL", "https://gitlab.com").rstrip("/")
TOKEN = os.environ.get("GITLAB_TOKEN") or sys.exit("Définir GITLAB_TOKEN (portée api).")
OUT = "logs/gitlab"
FAKE = "FAUX-jeton-ci-0123456789"


def api(method, path, data=None, raw=False):
    url = f"{API}/api/v4{path}"
    body = urllib.parse.urlencode(data, doseq=True).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method, headers={"PRIVATE-TOKEN": TOKEN})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            txt = r.read().decode("utf-8", "replace")
            return txt if raw else (json.loads(txt) if txt else None)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        sys.exit(f"API {method} {path} : {e.code} {e.read().decode()[:300]}")


def git(*args, push=False):
    cmd = ["git"]
    if push:  # authentification par en-tête, sans écrire le jeton dans .git/config
        cred = base64.b64encode(f"oauth2:{TOKEN}".encode()).decode()
        cmd += ["-c", f"http.{API}/.extraheader=Authorization: Basic {cred}"]
    subprocess.run(cmd + list(args), check=True)


def sha(ref="HEAD"):
    return subprocess.check_output(["git", "rev-parse", ref], text=True).strip()


def clean(trace):
    trace = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", trace)
    trace = re.sub(r"section_(start|end):\d+:[^\r\n]*\r?", "", trace)
    return "\n".join(l.rstrip() for l in trace.replace("\r", "\n").split("\n") if l.strip())


def wait_pipelines(pid, **query):
    """Attend que tous les pipelines correspondant à la requête soient terminés."""
    q = urllib.parse.urlencode(query)
    for _ in range(180):  # 30 min
        pls = api("GET", f"/projects/{pid}/pipelines?{q}") or []
        if pls and all(p["status"] in ("success", "failed", "canceled", "skipped", "manual") for p in pls):
            return pls
        time.sleep(10)
    sys.exit(f"Pipelines toujours en cours pour {query}")


def jobs(pid, pl):
    return api("GET", f"/projects/{pid}/pipelines/{pl['id']}/jobs?per_page=50") or []


def trace(pid, job):
    return clean(api("GET", f"/projects/{pid}/jobs/{job['id']}/trace", raw=True) or "")


def table(js):
    rows = [f"  {j['stage']:<10} {j['name']:<18} {j['status']:<9} {round(j.get('duration') or 0)} s" for j in js]
    return "\n".join(["  stage      job                statut    durée"] + sorted(rows))


def write(name, text):
    os.makedirs(OUT, exist_ok=True)
    with open(f"{OUT}/{name}", "w") as f:
        f.write(text.rstrip() + "\n")
    print(f"  -> {OUT}/{name}")


def main():
    dirty = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], text=True)
    if dirty.strip():
        sys.exit("Commiter ou mettre de côté les modifications en cours avant de lancer le script.")
    if subprocess.check_output(["git", "branch", "--show-current"], text=True).strip() != "main":
        sys.exit("Se placer sur la branche main (git checkout main).")
    me = api("GET", "/user")
    path = os.environ.get("GITLAB_PROJECT", f"{me['username']}/mpiflow")
    proj = api("GET", f"/projects/{urllib.parse.quote(path, safe='')}")
    if not proj:
        print(f"Création du projet privé {path}")
        proj = api("POST", "/projects", {"name": path.split("/")[-1], "visibility": "private"})
    pid, web = proj["id"], proj["web_url"]
    remote = proj["http_url_to_repo"]

    # variable masquée et protégée (fausse valeur)
    var = {"key": "FAKE_REGISTRY_TOKEN", "value": FAKE, "masked": "true", "protected": "true"}
    if api("GET", f"/projects/{pid}/variables/FAKE_REGISTRY_TOKEN"):
        api("PUT", f"/projects/{pid}/variables/FAKE_REGISTRY_TOKEN", var)
    else:
        api("POST", f"/projects/{pid}/variables", var)

    # --- Mission 1 : pipeline de branche sur main --------------------------------
    print("Push de main et attente du pipeline...")
    git("push", remote, "HEAD:refs/heads/main", push=True)
    main_sha = sha()
    pl = wait_pipelines(pid, sha=main_sha, ref="main")[0]
    js = jobs(pid, pl)
    by = {j["name"]: j for j in js}
    out = [f"Pipeline {pl['web_url']} (source : {pl['source']}, statut : {pl['status']})", table(js)]
    if "test" in by:
        out += ["", "--- fin du log du job test ---", "\n".join(trace(pid, by["test"]).splitlines()[-22:])]
    write("m1-pipeline-main.txt", "\n".join(out))
    if "registry_login" in by:
        t = [l for l in trace(pid, by["registry_login"]).splitlines()
             if re.search(r"ref=|masquage|MASKED|Login|vide", l)]
        write("m2-registry-main.txt", "Job registry_login sur main (branche protégée)\n" + "\n".join(t))

    # --- Mission 2 : merge request avec erreur volontaire ---------------------------
    br = "demo/lint-erreur"
    print("Branche de démonstration, merge request et erreur volontaire...")
    git("checkout", "-B", br)
    with open("tests/LINT_DEMO.md", "w") as f:
        f.write("Branche de démonstration du lint (mission 2), à ne pas fusionner.\n")
    git("add", "tests/LINT_DEMO.md")
    git("commit", "-m", "demo: branche de démonstration du lint")
    git("push", "-f", remote, f"HEAD:refs/heads/{br}", push=True)
    wait_pipelines(pid, ref=br)
    mr = (api("GET", f"/projects/{pid}/merge_requests?state=opened&source_branch={br}") or [None])[0] or \
        api("POST", f"/projects/{pid}/merge_requests",
            {"source_branch": br, "target_branch": "main", "title": "Démo lint (à ne pas fusionner)"})
    src = open("tests/test_mpi.c").read()
    with open("tests/test_mpi.c", "w") as f:
        f.write(src.replace("int errors = 0;", "int errors = 0; int tab[4]; tab[4] = rank; /* erreur volontaire */", 1))
    git("commit", "-m", "demo: erreur volontaire détectée par cppcheck", "tests/test_mpi.c")
    git("push", remote, f"HEAD:refs/heads/{br}", push=True)
    err_sha = sha()
    time.sleep(15)
    pls = wait_pipelines(pid, sha=err_sha)
    out = [f"Merge request {mr['web_url']}",
           f"Pipelines créés pour le commit {err_sha[:8]} : {len(pls)}"]
    out += [f"  #{p['id']} source={p['source']} ref={p['ref']} statut={p['status']}" for p in pls]
    mrpl = next((p for p in pls if p["source"] == "merge_request_event"), pls[0])
    js = jobs(pid, mrpl)
    by = {j["name"]: j for j in js}
    out += ["", table(js)]
    if "lint" in by:
        out += ["", "--- log du job lint ---"] + [l for l in trace(pid, by["lint"]).splitlines()
                                                    if re.search(r"cppcheck|error|Checking|tab\[|exit code|ERROR", l)]
    if "registry_login" in by:
        out += ["", "--- job registry_login dans le pipeline de MR (ref non protégée) ---"] + \
            [l for l in trace(pid, by["registry_login"]).splitlines() if re.search(r"ref=|vide|MASKED|Login", l)]
    write("m2-mr.txt", "\n".join(out))
    api("PUT", f"/projects/{pid}/merge_requests/{mr['iid']}", {"state_event": "close"})
    git("checkout", "tests/test_mpi.c")
    git("checkout", "-")
    git("branch", "-D", br)

    # --- Mission 2 : tag de version ------------------------------------------------
    print("Tag v0.1.0 et attente du job package...")
    git("tag", "-f", "v0.1.0", main_sha)
    git("push", "-f", remote, "refs/tags/v0.1.0", push=True)
    pl = wait_pipelines(pid, ref="v0.1.0")[0]
    js = jobs(pid, pl)
    by = {j["name"]: j for j in js}
    out = [f"Pipeline {pl['web_url']} (tag v0.1.0, statut : {pl['status']})", table(js)]
    if "package" in by:
        out += ["", "--- log du job package ---"] + [l for l in trace(pid, by["package"]).splitlines()
                                                      if re.search(r"tar|sha256|mpiflow-v|Uploading|artifact", l)]
        arts = by["package"].get("artifacts") or []
        out += ["", "Artefacts : " + ", ".join(f"{a['filename']} ({a['size']} o)" for a in arts)]
    write("m2-tag.txt", "\n".join(out))

    write("meta.tex", "\\renewcommand{\\depot}{\\url{%s}}" % web)
    print(f"\nTerminé. Projet : {web}")
    regenerate()


def regenerate():
    """Recompile le rapport et le Markdown si LaTeX et pandoc sont présents."""
    if subprocess.run(["which", "latexmk"], capture_output=True).returncode == 0:
        subprocess.run(["latexmk", "-g", "-silent", "carnet-de-bord.tex"])
    if subprocess.run(["which", "pandoc"], capture_output=True).returncode == 0:
        subprocess.run([sys.executable, "scripts/tex2md.py"])
    print("Commiter logs/gitlab/, carnet-de-bord.pdf et carnet-de-bord.md.")


if __name__ == "__main__":
    main()

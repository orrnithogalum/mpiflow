#!/usr/bin/env python3
"""figures.py -- figures du rapport construites à partir des preuves de logs/.

    python3 scripts/figures.py

  logs/figures/runs.tex    jobs exécutés selon l'événement déclencheur
                           (logs/github/runs.json ; à défaut, comportement attendu du workflow)
  logs/figures/chrono.tex  chronologie des jobs Slurm des scénarios de la mission 3
                           (logs/romeo/ ; à défaut, mini-cluster de reproduction, logs/)

Lancé par scripts/github_evidence.py, romeo/romeo.sh evidence et scripts/finalise.sh.
"""
import json
import os
import re
from datetime import datetime

OUT = "logs/figures"
JOBS = ["lint", "build", "test", "registry_login", "package", "test_slurm"]
ROWS = [
    ("push-main", r"push sur \texttt{main}"),
    ("sans-needs", r"\texttt{test} sans \texttt{needs}"),
    ("pr-lint", r"pull request, erreur cppcheck"),
    ("pr-build", r"pull request, + erreur de compilation"),
    ("tag", r"tag \texttt{v0.1.0}"),
    ("rc1", r"tag \texttt{v0.1.0-rc1}"),
    ("publier", r"\texttt{package} forcé depuis \texttt{main}"),
    ("hpc-polling", r"lancement manuel, ROMEO"),
    ("hpc-annulation", r"lancement manuel, annulé"),
]
S, F, K, C = "success", "failure", "skipped", "cancelled"
EXPECTED = {   # ce que le workflow doit produire (avant les runs réels)
    "push-main": [K, S, S, S, K, K], "sans-needs": [K, S, F, S, K, K],
    "pr-lint": [F, S, S, S, K, K], "pr-build": [F, F, K, S, K, K],
    "tag": [K, S, S, S, S, K], "rc1": None, "publier": [K, S, S, S, F, K],
    "hpc-polling": [K, S, S, S, K, S], "hpc-annulation": [K, S, S, S, K, C],
}


def glyph(x, y, c):
    if c == "success":
        return rf"\fill[oiVert] ({x},{y}) circle (0.15);"
    if c == "failure":
        return (rf"\fill[oiVermillon] ({x},{y}) circle (0.15);"
                rf"\draw[white, line width=1.1pt] ({x}-0.07,{y}-0.07) -- ({x}+0.07,{y}+0.07)"
                rf" ({x}-0.07,{y}+0.07) -- ({x}+0.07,{y}-0.07);")
    if c == "cancelled":
        return (rf"\fill[oiOrange] ({x},{y}) circle (0.15);"
                rf"\draw[white, line width=1.3pt] ({x}-0.08,{y}) -- ({x}+0.08,{y});")
    return rf"\draw[black!35] ({x},{y}) circle (0.11);"


def runs_figure():
    path = "logs/github/runs.json"
    real = os.path.exists(path)
    data = json.load(open(path)) if real else {}
    x0, dx, dy = 5.8, 1.82, 0.5
    out = [r"\begin{tikzpicture}[font=\sffamily\footnotesize]"]
    for i, name in enumerate(JOBS):
        # registry_login, test_slurm : coupés après « _ », sinon ils touchent la colonne voisine
        out.append(rf"\node[anchor=south, align=center, font=\ttfamily\scriptsize] at ({x0 + i * dx},0.2) "
                   rf"{{{name.replace('_', chr(92) + '_' + chr(92) * 2 + '[-2pt]')}}};")
    rows = [(k, t) for k, t in ROWS if not real or k in data]
    for r, (key, title) in enumerate(rows):
        y = -(r + 0.5) * dy
        if r % 2 == 0:
            out.append(rf"\fill[black!4] (0,{y - dy / 2}) rectangle ({x0 + 5 * dx + 0.6},{y + dy / 2});")
        out.append(rf"\node[anchor=west] at (0.05,{y}) {{{title}}};")
        if real:
            jobs = data[key]["jobs"]
            concl = [jobs.get(j, "skipped") for j in JOBS] if jobs else None
        else:
            concl = EXPECTED[key]
        if concl is None:
            out.append(rf"\draw[black!35, dashed] ({x0 - 0.3},{y}) -- ({x0 + 5 * dx + 0.3},{y});")
            out.append(rf"\node[fill={'black!4' if r % 2 == 0 else 'white'}, text=black!60, inner sep=1pt]"
                       rf" at ({x0 + 2.5 * dx},{y}) {{aucun run déclenché}};")
            continue
        for i, c in enumerate(concl):
            out.append(glyph(x0 + i * dx, y, c))
    yl = -(len(rows) + 0.9) * dy
    legend = [("success", "réussi"), ("failure", "échoué"), ("cancelled", "annulé"),
              ("skipped", "non exécuté (condition fausse ou dépendance en échec)")]
    x = 0.2
    for c, lab in legend:
        out.append(glyph(x, yl, c))
        out.append(rf"\node[anchor=west, font=\sffamily\scriptsize] at ({x + 0.2},{yl}) {{{lab}}};")
        x += 1.9 if c != "cancelled" else 2.0
    out.append(r"\end{tikzpicture}")
    src = (r"d'après les runs GitHub Actions du dépôt (\texttt{logs/github/runs.json})" if real else
           r"comportement attendu d'après \texttt{ci.yml}, en attendant les runs réels"
           r" (\texttt{scripts/github\_evidence.py} remplace cette figure)")
    cap = (r"\captionof{figure}{Jobs exécutés selon l'événement déclencheur, " + src +
           r". Une ligne par run ; \texttt{test\_slurm} tourne sur le runner auto-hébergé"
           r" \texttt{romeo-ssh}, qui soumet sur ROMEO, les autres jobs sur les runners de GitHub.}\label{fig:runs}")
    return "\n".join(out) + "\n" + cap + "\n"


def parse_sacct(path):
    recs = []
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$", line)
        if m:
            jid, _, state, sub, start, end, _ = m.groups()
            t = lambda s: datetime.fromisoformat(s) if re.match(r"\d{4}-", s) else None
            recs.append((jid, state.rstrip("+"), t(sub), t(start), t(end)))
    return recs


COL = {"COMPLETED": "oiVert", "FAILED": "oiVermillon", "TIMEOUT": "oiOrange",
       "NODE_FAIL": "oiPourpre", "REQUEUED": "oiPourpre", "PREEMPTED": "oiPourpre",
       "CANCELLED": "black!45"}


def chrono_figure():
    base = "logs/romeo" if os.path.exists("logs/romeo/m3-chronologie.txt") else "logs"
    scen = [l.strip().split("|", 1) for l in open(f"{base}/m3-scenarios.txt", encoding="utf-8") if "|" in l]
    recs = parse_sacct(f"{base}/m3-chronologie.txt")
    rows = []
    for jid, label in scen:
        rr = [r for r in recs if r[0] == jid]
        if rr:
            rows.append((jid, label, rr))
    ends = sorted(((rr[-1][4] or rr[-1][2]) - rr[0][2]).total_seconds() for _, _, rr in rows)
    tmax = ends[-1]
    # une attente exceptionnelle (file chargée) ne doit pas écraser les autres barres
    if len(ends) > 1 and tmax > 120 and tmax > 2.5 * ends[-2]:
        cap = float(-(-1.3 * ends[-2] // 10) * 10)
    else:
        cap = max(30.0, tmax)
    step = next(st for st in (10, 20, 30, 60, 120, 300, 600, 1200) if cap / st <= 7)
    width, lab, dy = 7.4, 3.9, 0.74
    k = width / cap
    out = [r"\begin{tikzpicture}[font=\sffamily\scriptsize]"]
    ytop = 0.25
    out.append(rf"\draw[black!55] ({lab},{ytop}) -- ({lab + width},{ytop});")
    for t in range(0, int(cap) + 1, step):
        out.append(rf"\draw[black!55] ({lab + t * k},{ytop}) -- ({lab + t * k},{ytop + 0.08}) "
                   rf"node[above, text=black!70] {{{t}}};")
    out.append(rf"\node[anchor=west, text=black!70] at ({lab + width + 0.1},{ytop + 0.18}) {{s}};")
    seen = []
    for i, (jid, label, rr) in enumerate(rows):
        y = -(i + 0.4) * dy
        t0 = rr[0][2]
        out.append(rf"\node[anchor=east, align=right] at ({lab - 0.15},{y}) {{{label}\\[-1pt]"
                   rf"{{\color{{black!55}}job {jid}}}}};")
        endx, final = lab, ""
        clip = lambda v: min(v, cap)
        for n, (_, state, sub, start, end) in enumerate(rr):
            s = (sub - t0).total_seconds()
            e = ((end or sub) - t0).total_seconds()
            b = (start - t0).total_seconds() if start else e
            if b > s:
                out.append(rf"\fill[oiCiel!60] ({lab + clip(s) * k},{y - 0.13}) rectangle "
                           rf"({lab + clip(b) * k},{y + 0.13});")
            if start and state in COL and e - b < 0.12 / k:      # exécution très courte : rester visible
                e = b + 0.12 / k
            if e > b:
                out.append(rf"\fill[{COL.get(state, 'black!45')}] ({lab + clip(b) * k},{y - 0.13}) rectangle "
                           rf"({lab + clip(e) * k},{y + 0.13});")
                if state not in seen:
                    seen.append(state)
            if e > cap:
                xz = lab + width
                out.append(rf"\draw[white, line width=2pt] ({xz - 0.3},{y - 0.2}) -- ({xz - 0.2},{y + 0.2});")
            endx = lab + clip(e) * k
            txt = state.replace("_", r"\_")
            if n < len(rr) - 1:
                out.append(rf"\draw[black!70] ({endx},{y - 0.2}) -- ({endx},{y + 0.2});")
                final += ("" if state == "REQUEUED" else txt + r"\\[-1pt]") + r"remis en file, puis "
            else:
                final += txt
        if "timeout CI" in label or len(rr) > 1:
            final = final.replace("CANCELLED", r"annulé (\texttt{scancel})")
        tend = ((rr[-1][4] or rr[-1][2]) - t0).total_seconds()
        if tend > cap:
            final += rf" à {int(tend)} s"
        out.append(rf"\node[anchor=west, align=left] at ({endx + 0.08},{y}) {{{final}}};")
    yl = -(len(rows) + 0.3) * dy
    out.append(rf"\fill[oiCiel!60] (0,{yl - 0.09}) rectangle (0.45,{yl + 0.09});")
    out.append(rf"\node[anchor=west] at (0.5,{yl}) {{PENDING (en file)}};")
    out.append(rf"\node[anchor=west] at (3.0,{yl}) {{RUNNING, terminé en :}};")
    x = 6.6                                 # après « RUNNING, terminé en : »
    order = ["COMPLETED", "FAILED", "TIMEOUT", "NODE_FAIL", "REQUEUED", "PREEMPTED"]
    for st in [o for o in order if o in seen]:
        out.append(rf"\fill[{COL[st]}] ({x},{yl - 0.09}) rectangle ({x + 0.45},{yl + 0.09});")
        out.append(rf"\node[anchor=west] at ({x + 0.5},{yl}) {{{st.replace('_', chr(92) + '_')}}};")
        x += 2.35
    out.append(r"\end{tikzpicture}")
    where = (r"sur ROMEO (\texttt{logs/romeo/m3-chronologie.txt})" if base != "logs" else
             r"sur le mini-cluster de reproduction (\texttt{logs/m3-chronologie.txt})")
    cap_txt = (r"\captionof{figure}{Chronologie des jobs Slurm des scénarios de la mission 3, " + where +
               r", d'après les heures de soumission, de début et de fin enregistrées par"
               r" \texttt{slurmdbd}. Le temps est compté depuis la soumission de chaque job.}"
               r"\label{fig:chrono}")
    return "\n".join(out) + "\n" + cap_txt + "\n"


POLL = re.compile(r"^\[\d\d:\d\d:\d\d\] \+\s*\d+s\s+job \d+\s+(\S+)")
TRACE = re.compile(r"^\[[\w.-]+:\d+\] (\[ ?\d+\]|\*\*\*|Signal|Failing|Process received)")


GARDE = re.compile(r"^== (Job|Environnement)|rang \d+ sur|MPI test|^SUCCESS|^FAILED|Node failure"
                   r"|CANCELLED AT|simulée|simulé")


def sortie(lines):
    """Dans la sortie d'un job Slurm, ne garde que les lignes qui portent le verdict."""
    out, dans, coupe = [], False, False
    for l in lines:
        if l.startswith("---- sortie du job"):
            dans, coupe = True, False
        elif dans and (l.startswith(("Verdict", "[code retour", "$ ", "---- ", "> Run")) or POLL.match(l)):
            dans = False
        if dans and not l.startswith("---- ") and not GARDE.search(l):
            if not coupe and not l.startswith("== "):
                out.append("   [...]")
                coupe = True
            continue
        coupe = coupe and dans
        out.append(l)
    return out


TABLE = re.compile(r"^  job\s+résultat\s+durée")
LIGNE_JOB = re.compile(r"^  (\S+)\s+(\S+)\s+")
RANG = re.compile(r"^(\s*)rang (\d+) sur (\S+)$")


def resserre(lines):
    """Tableau des jobs d'un run GitHub sur deux lignes, rangs MPI regroupés par nœud."""
    out, i = [], 0
    while i < len(lines):
        if TABLE.match(lines[i]):
            faits, ignores = [], []
            i += 1
            while i < len(lines) and LIGNE_JOB.match(lines[i]):
                job, res = LIGNE_JOB.match(lines[i]).groups()
                (ignores.append(job) if res == "skipped" else faits.append(f"{job} {res}"))
                i += 1
            out.append("  jobs exécutés : " + ", ".join(faits))
            if ignores:
                out.append("  jobs ignorés  : " + ", ".join(ignores))
            continue
        m = RANG.match(lines[i])
        if m:
            j = i
            while j + 1 < len(lines) and RANG.match(lines[j + 1]) \
                    and RANG.match(lines[j + 1]).group(3) == m.group(3):
                j += 1
            if j - i >= 2:
                fin = RANG.match(lines[j]).group(2)
                out.append(f"{m.group(1)}rangs {m.group(2)} à {fin} sur {m.group(3)}"
                           f"   [{j - i + 1} lignes regroupées]")
            else:
                out += lines[i:j + 1]
            i = j + 1
            continue
        out.append(lines[i])
        i += 1
    return out


def condense(src, dst):
    """Extrait lisible d'un log : relevés identiques du suivi, traces de pile et sortie du job abrégés."""
    lines = resserre(sortie(open(src, encoding="utf-8").read().replace("\x00", "").splitlines()))
    out, i = [], 0
    while i < len(lines):
        m = POLL.match(lines[i])
        if m:
            j = i
            while j + 1 < len(lines) and POLL.match(lines[j + 1]) \
                    and POLL.match(lines[j + 1]).group(1) == m.group(1):
                j += 1
            if j - i >= 3:
                out += [lines[i], f"   [... {j - i - 1} relevés identiques ...]", lines[j]]
            else:
                out += lines[i:j + 1]
            i = j + 1
        elif TRACE.match(lines[i]):
            j = i
            while j + 1 < len(lines) and TRACE.match(lines[j + 1]):
                j += 1
            out.append("   [... trace de la pile ...]" if j > i else lines[i])
            i = j + 1
        else:
            out.append(lines[i])
            i += 1
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")


def extraits():
    for d, motif in (("logs/romeo", "m3-"), ("logs/github", "m")):
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.startswith(motif) and f.endswith(".txt"):
                    condense(f"{d}/{f}", f"logs/extraits/{os.path.basename(d)}-{f}")


def main():
    extraits()
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("runs.tex", runs_figure), ("chrono.tex", chrono_figure)):
        with open(f"{OUT}/{name}", "w", encoding="utf-8") as f:
            f.write("% généré par scripts/figures.py : ne pas modifier à la main\n" + fn())
        print(f"{OUT}/{name} écrit")


if __name__ == "__main__":
    main()

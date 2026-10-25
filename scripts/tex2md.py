#!/usr/bin/env python3
"""tex2md.py -- produit carnet-de-bord.md (le livrable demandé par le sujet) à partir de
carnet-de-bord.tex, avec les mêmes preuves, numéros et figures que le PDF.

    python3 scripts/tex2md.py        # nécessite pandoc et pdflatex

Les blocs conditionnels suivent la présence des preuves dans logs/, les listings sont recopiés
depuis les fichiers du dépôt et chaque figure TikZ est compilée en PNG dans figures/.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

TEX = open("carnet-de-bord.tex", encoding="utf-8").read()


def balanced(s, i):
    """Indice juste après l'accolade fermante correspondant à s[i] == '{'."""
    depth = 0
    for j in range(i, len(s)):
        depth += {"{": 1, "}": -1}.get(s[j], 0)
        if depth == 0:
            return j + 1
    raise ValueError("accolades déséquilibrées")


def args(s, i, spec):
    """Lit des arguments à partir de s[i] : spec est une suite de 'o' (optionnel) et 'm'."""
    out = []
    for kind in spec:
        while i < len(s) and s[i] in " \n\t":
            i += 1
        if kind == "o":
            if i < len(s) and s[i] == "[":
                j = s.index("]", i)
                while s.count("{", i, j) != s.count("}", i, j):
                    j = s.index("]", j + 1)
                out.append(s[i + 1:j]); i = j + 1
            else:
                out.append("")
        else:
            j = balanced(s, i)
            out.append(s[i + 1:j - 1]); i = j
    return out, i


# ------------------------------------------------------------ état des preuves
ex = os.path.exists
flags = {"github": ex("logs/github/meta.tex"), "ghdemo": ex("logs/github/m2-pr.txt"),
         "ghhpc": ex("logs/github/m3-ci-polling.txt"), "cluster": ex("logs/cluster/meta.tex"),
         "brouillon": False}
meta = {"depot": "\\emph{URL du dépôt à compléter}", "clusterinfo": "\\emph{type et zone des VM à compléter}",
        "spackinstalltime": "\\emph{durée à compléter}", "mpilauncher": "srun", "ghsecret": "environnement",
        "etudiants": "Sylvain ROWE"}
for f in ("logs/github/meta.tex", "logs/cluster/meta.tex"):
    if ex(f):
        for k, v in re.findall(r"\\renewcommand\{\\(\w+)\}\{(.*)\}\s*$", open(f, encoding="utf-8").read(), re.M):
            meta[k] = v

body = TEX[TEX.index("\\section{Introduction}"):TEX.index("\\end{document}")]

# \ifnum\pdfstrcmp{\ghsecret}{depot}=0 A \else B \fi
body = re.sub(r"\\ifnum\\pdfstrcmp\{\\ghsecret\}\{depot\}=0\s?(.*?)\\else[ \t]*\n?(.*?)\\fi[ \t]*\n?",
              lambda m: m.group(1) if meta["ghsecret"] == "depot" else m.group(2), body, flags=re.S)


def resolve_ifs(s):
    """Résout les \\ifXXX ... \\else ... \\fi des drapeaux connus (imbrication comprise)."""
    tok = re.compile(r"(?:\\if(" + "|".join(flags) + r")|\\else|\\fi)(?![A-Za-z])(?:\{\})?[ \t]*\n?")
    out, stack, pos = [], [], 0
    active = lambda: all(c != e for c, e in stack)
    for m in tok.finditer(s):
        if active():
            out.append(s[pos:m.start()])
        if m.group(1):
            stack.append([flags[m.group(1)], False])
        elif m.group(0).startswith("\\else"):
            stack[-1][1] = True
        else:
            stack.pop()
        pos = m.end()
    out.append(s[pos:])
    return "".join(out)


body = resolve_ifs(body)


def expand(s, name, spec, fn):
    while True:
        m = re.search(r"\\" + name + r"(?![A-Za-z])", s)
        if not m:
            return s
        a, j = args(s, m.end(), spec)
        s = s[:m.start()] + fn(*a) + s[j:]


body = expand(body, "IfFileExists", "mmm", lambda f, yes, no: yes if ex(f) else no)
for k, v in meta.items():
    body = re.sub(r"\\" + k + r"(\{\})?(?![A-Za-z])", lambda m: v.replace("\\", "\\\\"), body)

# ------------------------------------------------------------ numérotation
counters = {"figure": 0, "listing": 0}
labels = {}
sec = [0, 0, 0]


def number_sections(s):
    out, pos = [], 0
    for m in re.finditer(r"\\(section|subsection|subsubsection)(?=\{)", s):
        if m.start() < pos:
            continue
        lvl = {"section": 0, "subsection": 1, "subsubsection": 2}[m.group(1)]
        sec[lvl] += 1
        sec[lvl + 1:] = [0] * (2 - lvl)
        num = ".".join(str(x) for x in sec[:lvl + 1])
        (title,), j = args(s, m.end(), "m")
        lab = re.match(r"\s*\\label\{([^}]*)\}", s[j:])
        if lab:
            labels[lab.group(1)] = num
        out.append(s[pos:m.start()] + "\\%s*{%s %s}" % (m.group(1), num, title))
        pos = j
    out.append(s[pos:])
    return "".join(out)


body = number_sections(body)
body = re.sub(r"\\label\{sec:[^}]*\}", "", body)

# ------------------------------------------------------------ figures en PNG
os.makedirs("figures", exist_ok=True)
pre = TEX[:TEX.index("\\begin{document}")]
pre = pre.replace("\\documentclass[11pt,a4paper]{article}", "\\documentclass[11pt,border=4pt]{standalone}")
pre = re.sub(r"\\usepackage\[a4paper[^\n]*geometry\}\n", "", pre)
pre = re.sub(r"\\IfFileExists\{logs/[^\n]*\n", "", pre)
pre = pre.replace("\\brouillontrue", "")


def tikz_png(code, n):
    png = f"figures/figure-{n}.png"
    with tempfile.TemporaryDirectory() as d:
        src = os.path.join(d, "f.tex")
        open(src, "w", encoding="utf-8").write(pre + "\\begin{document}\n" + code + "\n\\end{document}\n")
        r = subprocess.run(["pdflatex", "-interaction=nonstopmode", "-output-directory", d, src],
                           capture_output=True, text=True, cwd=os.getcwd())
        if r.returncode or not ex(os.path.join(d, "f.pdf")):
            print(f"figure {n} : échec de compilation, ignorée", file=sys.stderr)
            return None
        subprocess.run(["pdftoppm", "-r", "160", "-png", "-singlefile",
                        os.path.join(d, "f.pdf"), png[:-4]], check=True)
    return png


def figure_block(inner):
    if "\\input{" in inner:
        f = re.search(r"\\input\{([^}]*)\}", inner).group(1)
        inner = inner.replace(re.search(r"\\input\{[^}]*\}", inner).group(0),
                              open(f, encoding="utf-8").read())
    tikz = re.search(r"\\begin\{tikzpicture\}.*?\\end\{tikzpicture\}", inner, re.S)
    capm = re.search(r"\\captionof\{figure\}", inner)
    cap, j = args(inner, capm.end(), "m")
    after = inner[j:]
    lab = re.match(r"\s*\\label\{([^}]*)\}", after)
    counters["figure"] += 1
    n = counters["figure"]
    if lab:
        labels[lab.group(1)] = str(n)
        after = after[lab.end():]
    comment = after.split("\\commentaire", 1)[1] if "\\commentaire" in after else after
    png = tikz_png(tikz.group(0), n) if tikz else None
    img = f"\\includegraphics{{{png}}}" if png else "\\emph{(figure : voir le PDF)}"
    return (f"\n\n{img}\n\n\\emph{{Figure {n}. {cap[0]}}}\n\n" + comment + "\n\n")


body = re.sub(r"\\begin\{figtexte\}(.*?)\\end\{figtexte\}", lambda m: figure_block(m.group(1)), body, flags=re.S)


# ------------------------------------------------------------ listings
def read_lines(path, opts):
    lines = open(path, encoding="utf-8").read().splitlines()
    lr = re.search(r"linerange=\{([^}]*)\}", opts)
    fl, ll = re.search(r"firstline=(\d+)", opts), re.search(r"lastline=(\d+)", opts)
    if lr:
        keep = []
        for part in lr.group(1).split(","):
            a, _, b = part.partition("-")
            keep += lines[int(a) - 1:int(b or a)]
        return keep
    return lines[(int(fl.group(1)) - 1 if fl else 0):(int(ll.group(1)) if ll else None)]


def preuve(opts, path, cap):
    counters["listing"] += 1
    n = counters["listing"]
    lab = re.search(r"label=([^,\]]+)", opts)
    if lab:
        labels[lab.group(1).strip()] = str(n)
    code = "\n".join(read_lines(path, opts))
    return ("\n\n\\begin{verbatim}\n" + code + "\n\\end{verbatim}\n\n"
            + "\\emph{Listing %d. %s (\\texttt{%s})}\n\n" % (n, cap.replace("\n", " "), path.replace("_", "\\_")))


def preuveou(o1, f1, c1, o2, f2, c2):
    return preuve(o1, f1, c1) if ex(f1) else preuve(o2, f2, c2)


# les listings sont numérotés dans l'ordre du texte : un seul passage séquentiel
def listings(s):
    out, pos = [], 0
    pat = re.compile(r"\\preuve(ou)?(?![A-Za-z])")
    while True:
        m = pat.search(s, pos)
        if not m:
            out.append(s[pos:]); return "".join(out)
        out.append(s[pos:m.start()])
        if m.group(1):
            a, j = args(s, m.end(), "ommomm")
            out.append(preuveou(*a))
        else:
            a, j = args(s, m.end(), "omm")
            out.append(preuve(*a))
        pos = j


body = listings(body)


# ------------------------------------------------------------ renvois et macros
def ref(m):
    return labels.get(m.group(1), "?")


body = re.sub(r"~?\\ref\{([^}]*)\}", lambda m: " " + ref(m), body)


def code(text):
    """\\code et \\fic lisent leur argument en verbatim : l'échapper pour pandoc."""
    out, i = [], 0
    while True:
        m = re.search(r"\\(code|fic)\{", text[i:])
        if not m:
            return "".join(out) + text[i:]
        a = i + m.start(); b = i + m.end(); depth = 1; j = b
        while depth:
            depth += {"{": 1, "}": -1}.get(text[j], 0); j += 1
        arg = text[b:j - 1]
        esc = "".join({"\\": r"\textbackslash{}", "$": r"\$", "_": r"\_", "%": r"\%", "&": r"\&",
                       "#": r"\#", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}",
                       "{": r"\{", "}": r"\}"}.get(c, c) for c in arg)
        out.append(text[i:a] + r"\texttt{" + esc.replace("--", "-{}-").replace("--", "-{}-") + "}")
        i = j


body = code(body)
body = expand(body, "enquote", "m", lambda t: "« " + t + " »")
body = expand(body, "afaire", "m", lambda t: "\\emph{[à compléter : " + t + "]}")
body = body.replace("$\\neq$", "≠").replace("$\\times$", "×").replace("$\\to$", "→")
body = re.sub(r"\\(medskip|bigskip|clearpage|newpage|noindent)\b", "", body)

head = (r"\documentclass{article}\begin{document}"
        "\n\\section*{Carnet de bord : DevOps pour le HPC (Cours 6, séance en pédagogie inversée)}\n"
        f"{meta['etudiants']}, M2 CHPS, UE CHPS0902. Dépôt : {meta['depot']}, tag \\texttt{{seance-inversee}}. "
        "Version mise en page : \\texttt{carnet-de-bord.pdf}.\n\n")
tex = head + body + "\\end{document}\n"
r = subprocess.run(["pandoc", "-f", "latex-smart", "-t", "gfm", "--wrap=none"], input=tex,
                   capture_output=True, text=True)
if r.returncode:
    open("/tmp/tex2md-debug.tex", "w").write(tex)
    sys.exit(r.stderr)
md = r.stdout
md = re.sub(r"<img src=\"([^\"]+)\" />", r"![](\1)", md)
open("carnet-de-bord.md", "w", encoding="utf-8").write(md)
print("carnet-de-bord.md écrit (%d lignes, %d figures, %d listings)"
      % (md.count("\n"), counters["figure"], counters["listing"]))

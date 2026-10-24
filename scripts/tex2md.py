#!/usr/bin/env python3
"""tex2md.py -- produit carnet-de-bord.md (demandé par le sujet) à partir de carnet-de-bord.tex.

    python3 scripts/tex2md.py        # nécessite pandoc

Les listings sont recopiés depuis les fichiers du dépôt, les figures TikZ renvoient au PDF,
et les blocs conditionnels (preuves GitLab/GCP) suivent la présence des fichiers de logs/.
"""
import os, re, subprocess, sys

src = open("carnet-de-bord.tex", encoding="utf-8").read()
flags = {"gitlab": os.path.exists("logs/gitlab/meta.tex"), "gcp": os.path.exists("logs/gcp/meta.tex")}
meta = {"\\depot": "*URL du dépôt à compléter*", "\\gcpinfo": "*à compléter*", "\\spackinstalltime": "*à compléter*"}
for f in ("logs/gitlab/meta.tex", "logs/gcp/meta.tex"):
    if os.path.exists(f):
        for k, v in re.findall(r"\\renewcommand\{(\\\w+)\}\{(.*)\}\s*$", open(f).read(), re.M):
            meta[k] = re.sub(r"\\(texttt|url)\{([^}]*)\}", r"\2", v)

body = src[src.index("\\section{Introduction}"):src.index("\\end{document}")]
# conditionnels \ifgitlab / \ifgcp (non imbriqués)
for name, on in flags.items():
    body = re.sub(r"\\if%s(.*?)(?:\\else(.*?))?\\fi" % name,
                  lambda m: (m.group(1) if on else (m.group(2) or "")), body, flags=re.S)
for k, v in meta.items():
    body = body.replace(k + "{}", v).replace(k, v)


def listing(m):
    opts, path = m.group(1) or "", m.group(2)
    if not os.path.exists(path):
        return ""
    lines = open(path, encoding="utf-8").read().splitlines()
    lr = re.search(r"linerange=\{([^}]*)\}", opts)
    fl, ll = re.search(r"firstline=(\d+)", opts), re.search(r"lastline=(\d+)", opts)
    if lr:
        keep = []
        for part in lr.group(1).split(","):
            a, b = part.split("-")
            keep += lines[int(a) - 1:int(b)]
        lines = keep
    else:
        lines = lines[(int(fl.group(1)) - 1 if fl else 0):(int(ll.group(1)) if ll else None)]
    cap = re.search(r"caption=\{(.*)\}\s*,\s*(?:label|$)", opts, re.S) or re.search(r"caption=\{(.*)\}", opts, re.S)
    out = "\n\\begin{verbatim}\n" + "\n".join(lines) + "\n\\end{verbatim}\n"
    if cap:
        out += "\n\\emph{%s}\n" % cap.group(1).strip()
    return out


body = re.sub(r"\\lstinputlisting(?:\[(.*?)\])?\{([^}]*)\}", listing, body, flags=re.S)
body = re.sub(r"\\begin\{tikzpicture\}.*?\\end\{tikzpicture\}", r"\\emph{(figure : voir le PDF)}", body, flags=re.S)
body = re.sub(r"\\IfFileExists\{[^}]*\}\{\}\{\}", "", body)
def code(text):
    """\\code{...} lit son argument en verbatim : l'échapper pour pandoc."""
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
                       "#": r"\#", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}.get(c, c) for c in arg)
        out.append(text[i:a] + r"\texttt{" + esc + "}")
        i = j


body = code(body)
body = re.sub(r"\\afaire\{", r"\\emph{À compléter : ", body)
body = re.sub(r"\\enquote\{([^}]*)\}", r"« \1 »", body)
body = body.replace("\\appendix", "").replace("$\\neq$", "≠").replace("$\\to$", "→").replace("$\\times$", "×")

head = r"""\documentclass{article}\begin{document}
\section*{Carnet de bord : DevOps pour le HPC (Cours 6, séance en pédagogie inversée)}
Sylvain ROWE, M2 CHPS, UE CHPS0902. Version PDF : \texttt{carnet-de-bord.pdf} (figures et mise en page complètes).
"""
tex = head + body + "\\end{document}\n"
md = subprocess.run(["pandoc", "-f", "latex", "-t", "gfm", "--wrap=none"], input=tex,
                    capture_output=True, text=True)
if md.returncode:
    sys.exit(md.stderr)
open("carnet-de-bord.md", "w", encoding="utf-8").write(md.stdout)
print("carnet-de-bord.md écrit (%d lignes)" % md.stdout.count("\n"))

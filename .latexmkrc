# latexmk : compile carnet-de-bord.tex avec pdfLaTeX (aucune option particulière requise)
$pdf_mode = 1;
$pdflatex = 'pdflatex -file-line-error -interaction=nonstopmode %O %S';
@default_files = ('carnet-de-bord.tex');

all: hld.pdf

%.pdf: %.md
	pandoc -V 'header-includes:\usepackage{array}' \
	       -V 'header-includes:\usepackage{dsfont}' \
	       -V 'header-includes:\usepackage{mathrsfs}' \
	       -V 'header-includes:\usepackage{enumitem}' \
	       -V 'mainfont:Times New Roman' \
	       -V geometry:margin=2cm,paper=a4paper \
	       --latex-engine=xelatex \
	       -o $@ $<

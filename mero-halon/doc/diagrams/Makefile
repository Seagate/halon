DOTS=$(wildcard *.dot)
UMLS=$(wildcard *.uml)
DDST=$(DOTS:%.dot=%.png)
DUML=$(UMLS:%.uml=%.png)

all: $(DDST) $(DUML)

%.png:%.dot
	dot -Tpng -o$@ $<

%.png:%.uml
	plantuml $<

clean:
	rm -rf $(DDST) $(DUML)

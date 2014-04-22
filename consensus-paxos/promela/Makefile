
prom:
	grep -rl --include "*.hs" promela ../src | runhaskell commentExtractor.hs promela > extracted.pml
	spin -h main.pml

test:
	grep -rl --include "*.hs" promela ../src | runhaskell commentExtractor.hs promela > extracted.pml
	spin -h -n1366836638 main.pml

verify:
	grep -rl --include "*.hs" promela ../src | runhaskell commentExtractor.hs promela > extracted.pml
	spin -a main.pml
	gcc -O2 -o pan pan.c -DSAFETY -DVECTORSZ=10000 -DCOLLAPSE -DMA=60
	# -DMA=120
	./pan -m50000 -w27

ispin:
	grep -rl --include "*.hs" promela ../src | runhaskell commentExtractor.hs promela -x > extracted.pml
	ispin main.pml

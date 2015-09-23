MODELS=timer rs

verify: $(MODELS)

$(MODELS):
	spin -a $@.pml
	gcc -O2 -w -o $@ pan.c -DMEMLIM=1024 -O2 -DXUSAFE -DSAFETY -DNOCLAIM -DCOLLAPSE
	./$@ -m1000

clean:
	-rm $(MODELS)
	-rm pan.*

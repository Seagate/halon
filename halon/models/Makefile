MODELS=timer rs

verify: $(MODELS)

$(MODELS):
	spin -a $@.pml
	gcc -O2 -DSAFETY -w -o $@ pan.c -DCOLLAPSE
	./$@ -w30

clean:
	-rm $(MODELS)
	-rm pan.*

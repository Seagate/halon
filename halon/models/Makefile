
verify: pan
	./pan -w30
	rm pan

pan.c: rs.pml
	spin -a rs.pml

# See http://spinroot.com/spin/Man/Roadmap.html
# See http://spinroot.com/spin/Man/Pan.html
pan: pan.c
	gcc -O2 -DSAFETY -w -o pan pan.c -DCOLLAPSE

clean:
	rm pan pan.* rs.pml.trail

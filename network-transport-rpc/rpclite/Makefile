
ifndef MERO_ROOT
$(error The variable MERO_ROOT is undefined. Please, make it point to the mero build tree.)
endif

RUNDIR=/var/mero/halon
FF2C=$(MERO_ROOT)/xcode/ff2c/ff2c
CC=gcc
CFLAGS=-c -I$(MERO_ROOT)/extra-libs/db4/build_unix -I$(MERO_ROOT) \
       -I$(MERO_ROOT)/extra-libs/cunit/CUnit/Headers\
	   -I$(MERO_ROOT)/extra-libs/yaml/include\
	   -Wno-attributes -Werror -g -DM0_INTERNAL='' -DM0_EXTERN=extern

libdirs=$(MERO_ROOT)/mero/.libs\
        $(MERO_ROOT)/extra-libs/cunit/CUnit/Sources/.libs

empty=
sp=$(empty) $(empty)

ENV=LD_LIBRARY_PATH=$(subst $(sp),:,$(libdirs)) M0_CORE_DIR=$(MERO_ROOT)

DEBUGGER=

LD_SEARCH_PATH=$(foreach dir,$(libdirs),-L$(dir))
HLD_SEARCH_PATH=$(foreach dir,$(libdirs),--extra-lib-dirs=$(dir))

LDFLAGS=$(LD_SEARCH_PATH) -lmero -lcunit
#		-lgalois -lmero -lmero-ut -lmero-xcode-ff2c -lmero-net-test

SOURCES=rpclite_fop_ff.c rpclite_fop.c rpclite.c rpclite_fom.c rpclite_sender_fom.c

OBJECTS=$(SOURCES:.c=.o)

runclient: test2
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(DEBUGGER) $(CURDIR)/test2"

runserver: test2
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(DEBUGGER) $(CURDIR)/test2 -s"

runclient3: test3
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/test3"

runserver3: test3
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/test3 -s"

runtest4: test4
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/test4"

runtest7: test7
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/test7"

runtest9: test9
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/test9"

runtest: test
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/test"

runtestv: test
	sudo sh -c "cd $(RUNDIR) && $(ENV) valgrind $(CURDIR)/test"

run-test-epoch: test-epoch
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/test-epoch"

run-dummyService: dummyService
	sudo sh -c "cd $(RUNDIR) && $(ENV) $(CURDIR)/dummyService $(RPC_ADDR)"

test9: $(OBJECTS) test9.o
	$(CC) $(OBJECTS) test9.o $(LDFLAGS) -o $@

test7: $(OBJECTS) test7.o
	$(CC) $(OBJECTS) test7.o $(LDFLAGS) -o $@

test4: $(OBJECTS) test4.o
	$(CC) $(OBJECTS) test4.o $(LDFLAGS) -o $@

test3: $(OBJECTS) test3.o
	$(CC) $(OBJECTS) test3.o $(LDFLAGS) -o $@

test: $(OBJECTS) test.o
	$(CC) $(OBJECTS) test.o $(LDFLAGS) -o $@

test2: $(OBJECTS) test2.o
	$(CC) $(OBJECTS) test2.o $(LDFLAGS) -o $@

test-epoch: $(OBJECTS) test-epoch.o
	$(CC) $(OBJECTS) test-epoch.o $(LDFLAGS) -o $@

dummyService: $(OBJECTS) dummyService.o
	$(CC) $(OBJECTS) dummyService.o $(LDFLAGS) -o $@

loadmero:
	sudo GENDERS=$(GENDERS) M0_CORE_DIR=$(MERO_ROOT) ./st insmod

unloadmero:
	sudo GENDERS=$(GENDERS) M0_CORE_DIR=$(MERO_ROOT) ./st rmmod

.c.o:
	$(CC) $(CFLAGS) $< -o $@

rpclite_fop_ff.c: rpclite_fop.ff
	$(FF2C) rpclite_fop.ff

rpclite_fop_ff.h: rpclite_fop.ff
	$(FF2C) rpclite_fop.ff

clean:
	rm -f rpclite_fop_ff.h
	rm -f rpclite_fop_ff.c
	sudo rm -rf m0.trace*
	sudo rm -rf *.db*
	sudo rm -rf *.stob
	sudo rm -rf *.o
	rm -f test
	rm -f test2
	rm -f test3
	rm -f test4
	rm -f test-epoch
	rm -f dummyService

ifndef MERO_ROOT
$(error The variable MERO_ROOT is undefined. Please, make it point to the mero build tree.)
endif
RPCLITE_PREFIX=../../rpclite/rpclite

FF2C=$(MERO_ROOT)/xcode/ff2c/ff2c
CC=gcc
CFLAGS=-c -I$(MERO_ROOT)/extra-libs/db4/build_unix -I$(MERO_ROOT) \
	   -I$(MERO_ROOT)/extra-libs/cunit/CUnit/Headers \
	   -Wno-attributes -Werror -g -DM0_INTERNAL='' -DM0_EXTERN=extern \
       -I$(RPCLITE_PREFIX)

libdirs=$(MERO_ROOT)/mero/.libs \
        $(MERO_ROOT)/extra-libs/cunit/CUnit/Sources/.libs

empty= 
sp=$(empty) $(empty)

ENV=LD_LIBRARY_PATH=$(subst $(sp),:,$(libdirs)) M0_CORE_DIR=$(MERO_ROOT)

LD_SEARCH_PATH=$(foreach dir,$(libdirs),-L$(dir))
HLD_SEARCH_PATH=$(foreach dir,$(libdirs),--extra-lib-dirs=$(dir))

LDFLAGS=$(LD_SEARCH_PATH) -lmero -pthread

SOURCES=$(RPCLITE_PREFIX)/rpclite_fop_ff.c \
		$(RPCLITE_PREFIX)/rpclite.c \
		$(RPCLITE_PREFIX)/rpclite_fop.c \
		$(RPCLITE_PREFIX)/rpclite_fom.c \
		$(RPCLITE_PREFIX)/rpclite_sender_fom.c \
        hastate.c \
        hastate_fops.c \
        hastate_foms.c
OBJECTS=$(SOURCES:.c=.o) 

TEST_NID = $(shell sudo lctl list_nids | grep o2ib | head -1)

runtest: test
	sudo $(ENV) ./test $(TEST_NID):12345:34:500 $(TEST_NID):12345:35:1

test: $(OBJECTS) test.o
	$(CC) $(OBJECTS) $@.o $(LDFLAGS) -o $@

dummy_mero: $(OBJECTS) dummy_mero.o
	$(CC) $(OBJECTS) $@.o $(LDFLAGS) -o $@

.c.o:
	$(CC) $(CFLAGS) $< -o $@

clean:
	rm -f rpclite_fop_ff.h
	rm -f rpclite_fop_ff.c
	sudo rm -rf m0.trace*
	sudo rm -rf *.db*
	sudo rm -rf *.stob
	sudo rm -rf *.o
	rm -f test dummy_mero

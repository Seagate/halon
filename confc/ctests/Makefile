
ifndef MERO_ROOT
$(error The variable MERO_ROOT is undefined. Please, make it point to the mero build tree.)
endif
RPCLITE_PREFIX=../../rpclite/rpclite

FF2C=$(MERO_ROOT)/xcode/ff2c/ff2c
CC=gcc
CFLAGS=-c -I$(MERO_ROOT) \
	   -Wno-attributes -Werror -g -DM0_INTERNAL='' -DM0_EXTERN=extern \
       -I$(RPCLITE_PREFIX)

libdirs=$(MERO_ROOT)/mero/.libs

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
		$(RPCLITE_PREFIX)/rpclite_sender_fom.c 
OBJECTS=$(SOURCES:.c=.o) 

runconfc_test_file: confc_test
	sudo -E $(ENV) sh -c "lctl list_nids | head -1 | xargs ./confc_test " > confc_test_out.txt

runconfc_test: confc_test 
	sudo $(ENV) sh -c "lctl list_nids | head -1 | xargs ./confc_test "

# This test takes as argument a local RPC address and the confd RPC address.
# The confd address is taken from $MERO_ROOT/m0t1fs/linux_kernel/st/st
runconf_poll_once: conf_poll_once
	sudo $(ENV) sh -c \
		'./conf_poll_once `lctl list_nids | head -1`:12345:34:401 `lctl list_nids | head -1`:12345:34:1001' \
		&& echo confd is healthy || echo confd has failed

testconfmon:
	sudo $(ENV) ./testconfmon.sh

confmon: conf_poll_once
	sudo $(ENV) ./confmon.sh

confc_test: $(OBJECTS) confc_test.o
	$(CC) $(OBJECTS) $@.o $(LDFLAGS) -o $@

conf_poll_once: $(OBJECTS) conf_poll_once.o
	$(CC) $(OBJECTS) $@.o $(LDFLAGS) -o $@

ST = $(MERO_ROOT)/m0t1fs/linux_kernel/st/st

loadmero:
	sudo M0_CORE_DIR=$(MERO_ROOT) $(ST) sstart

.c.o:
	$(CC) $(CFLAGS) $< -o $@


rpclite_fop_ff.c: $(RPCLITE_PREFIX)/rpclite_fop.ff
	$(FF2C) rpclite_fop.ff

rpclite_fop_ff.h: $(RPCLITE_PREFIX)/rpclite_fop.ff
	$(FF2C) rpclite_fop.ff

clean:
	rm -f rpclite_fop_ff.h
	rm -f rpclite_fop_ff.c
	sudo rm -rf m0.trace*
	sudo rm -rf *.db*
	sudo rm -rf *.stob
	sudo rm -rf *.o
	rm -f confc_test
	rm -f conf_poll_once

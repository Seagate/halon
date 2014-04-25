
ifndef MERO_ROOT
$(error The variable MERO_ROOT is undefined. Please, make it point to the mero build tree.)
endif
RPCLITE_PREFIX=$(shell pwd)/../network-transport-rpc/rpclite

CC=gcc
CFLAGS=-c -I$(MERO_ROOT)/extra-libs/db4/build_unix -I$(MERO_ROOT) \
       -I$(MERO_ROOT)/extra-libs/cunit/CUnit/Headers\
	   -I$(MERO_ROOT)/extra-libs/yaml/include\
	   -I$(RPCLITE_PREFIX)\
	   -Wno-attributes -Werror -g -DM0_INTERNAL='' -DM0_EXTERN=extern
export CFLAGS

libdirs=$(MERO_ROOT)/mero/.libs \
        $(MERO_ROOT)/extra-libs/cunit/CUnit/Sources/.libs

empty=
sp=$(empty) $(empty)

ENV=LD_LIBRARY_PATH=$(subst $(sp),:,$(libdirs)) M0_CORE_DIR=$(MERO_ROOT)
export ENV

LD_SEARCH_PATH=$(foreach dir,$(libdirs),-L$(dir))
HLD_SEARCH_PATH=$(foreach dir,$(libdirs),--extra-lib-dirs=$(dir))

LDFLAGS=$(LD_SEARCH_PATH) -lmero -lcunit
export LDFLAGS

CONFIGURE_FLAGS:=--extra-include-dirs=$(MERO_ROOT) --extra-include-dirs=$(MERO_ROOT)/extra-libs/db4/build_unix $(HLD_SEARCH_PATH) $(PROF_FLAGS) $(DEBUG_FLAGS)

build: configure
	cabal build

install: build
	cabal copy
	cabal register

haddock: configure
	cabal haddock

configure:
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal configure --enable-tests $(CONFIGURE_FLAGS)

test: build
	sudo -E $(ENV) $(RPCLITE_PREFIX)/st sstart confd
	sudo -E $(ENV) sh -c \
		'./dist/build/testconfc/testconfc `lctl list_nids | head -1`:12345:35:401 `lctl list_nids | head -1`:12345:34:1' > testconfc_out.txt
	make -C ctests runconfc_test_file; sudo -E $(ENV) $(RPCLITE_PREFIX)/st sstop confd
	diff -c ctests/confc_test_out.txt testconfc_out.txt

testconfc: build
	sudo -E $(ENV) sh -c \
		'./dist/build/testconfc/testconfc `lctl list_nids | head -1`:12345:35:401 `lctl list_nids | head -1`:12345:34:1'

collect_node_addresses: build
	sudo -E $(ENV) sh -c \
		'./dist/build/collect_node_addresses/collect_node_addresses `lctl list_nids | head -1`:12345:35:401 `lctl list_nids | head -1`:12345:34:1'

loadmero:
	sudo sysctl -w kernel.randomize_va_space=0
	sudo M0_CORE_DIR=$(MERO_ROOT) $(RPCLITE_PREFIX)/st insmod

.c.o:
	$(CC) $(CFLAGS) $< -o $@

clean:
	make -C ctests clean
	cabal clean
	rm -f rpclite_fop_ff.h
	rm -f rpclite_fop_ff.c
	sudo rm -rf m0.trace*
	sudo rm -rf *.db*
	sudo rm -rf *.stob
	sudo rm -rf *.o

ci: clean install haddock test

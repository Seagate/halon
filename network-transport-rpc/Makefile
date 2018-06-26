# This Makefile is DEPRECATED. It should not be called recursively.
#
# If there are any required targets, they should be moved to the toplevel
# Makefile, or to be called as a part of setup / test run.
#

CABAL = cabal $(CABAL_SANDBOX)

ifndef M0_SRC_DIR
$(error The variable M0_SRC_DIR is undefined. Please, make it point to the mero build tree.)
endif

FF2C=$(M0_SRC_DIR)/xcode/ff2c/ff2c

#libdirs=$(M0_SRC_DIR)/xcode/ff2c/.libs\
#		$(M0_SRC_DIR)/net/test/.libs\
#		$(M0_SRC_DIR)/extra-libs/galois/src/.libs\
#		$(M0_SRC_DIR)/mero/.libs\
#		$(M0_SRC_DIR)/extra-libs/db4/build_unix\
#		$(M0_SRC_DIR)/extra-libs/cunit/CUnit/Sources/.libs\
#		$(M0_SRC_DIR)/ut/.libs

libdirs=$(M0_SRC_DIR)/mero/.libs

empty=
sp=$(empty) $(empty)

ENV=LD_LIBRARY_PATH=$(subst $(sp),:,$(libdirs)) NTR_DB_DIR=$(NTR_DB_DIR)

LD_SEARCH_PATH=$(foreach dir,$(libdirs),-L$(dir))
HLD_SEARCH_PATH=$(foreach dir,$(libdirs),--extra-lib-dirs=$(dir))
EXTRAINCLUDE=--extra-include-dirs=$(M0_SRC_DIR)

#PROF_FLAGS=--enable-library-profiling --enable-executable-profiling
PROF_FLAGS=

#DEBUG_FLAGS=-f debug
DEBUG_FLAGS=

LDFLAGS=$(LD_SEARCH_PATH) -lmero
# -lgalois -lmero-ut -lmero-xcode-ff2c -lmero-net-test

CONFIGURE_FLAGS:=$(EXTRAINCLUDE) $(HLD_SEARCH_PATH) $(PROF_FLAGS) $(DEBUG_FLAGS)

build: configure
	$(CABAL) build
	make -C rpclite dummyService

install: build
	$(CABAL) copy
	$(CABAL) register

haddock: configure
	$(CABAL) haddock

configure: rpclite/rpclite_fop_ff.c rpclite/rpclite_fop_ff.h
	$(CABAL) configure --enable-tests $(CONFIGURE_FLAGS)

rpclite/rpclite_fop_ff.c: rpclite/rpclite_fop.ff
	$(FF2C) rpclite/rpclite_fop.ff

rpclite/rpclite_fop_ff.h: rpclite/rpclite_fop.ff
	$(FF2C) rpclite/rpclite_fop.ff

test: testnt testch testtransport

loadmero:
	sudo sysctl -w kernel.randomize_va_space=0
	sudo GENDERS=$(GENDERS) M0_CORE_DIR=$(M0_SRC_DIR) ./rpclite/st insmod

unloadmero:
	sudo GENDERS=$(GENDERS) M0_CORE_DIR=$(M0_SRC_DIR) ./rpclite/st rmmod

testrpcliteclient:
	sudo $(ENV) dist/build/testrpclite/testrpclite

testrpcliteserver:
	sudo $(ENV) dist/build/testrpclite/testrpclite -s

ghcich:
	sudo $(ENV) /opt/ghc/ghc-7.6.1.bin/bin/ghci tests/TestCH.hs -itests -i. -idist/build dist/build/rpclite/*.o $(LDFLAGS)

testnt:
	sudo $(ENV) dist/build/TestNT/TestNT

testch:
	sudo $(ENV) dist/build/TestCH/TestCH

testtutorial: build
	sudo $(ENV) dist/build/tutorial-server/tutorial-server "0@lo:12345:34:2" &
	sleep 30
	sudo $(ENV) dist/build/tutorial-client/tutorial-client "0@lo:12345:34:4" "0@lo:12345:34:2:0"
	sudo pkill tutorial-server

testchrpc: TEST_NID := $(shell sudo lctl list_nids | grep o2ib | head -1)
testchrpc:
	sudo $(ENV) dist/build/ch-server/ch-server "$(TEST_NID):12345:34:2" > ch-server.stdout &
	../mero-halon/scripts/wait_contents 120 ch-server.stdout ready \
		|| (sudo pkill ch-server && false)
	sudo $(ENV) dist/build/ch-client/ch-client "$(TEST_NID):12345:34:4" "$(TEST_NID):12345:34:2:10" \
		|| (sudo pkill ch-server && false)
	sudo $(ENV) dist/build/ch-client/ch-client "$(TEST_NID):12345:34:4" "$(TEST_NID):12345:34:2:10" \
		|| (sudo pkill ch-server && false)
	sudo pkill ch-server

testchrpc2: TEST_NID := $(shell sudo lctl list_nids | grep o2ib | head -1)
testchrpc2:
	sudo $(ENV) dist/build/ch-delay-server/ch-delay-server s2 "$(TEST_NID):12345:34:2" 2> ch-delay-server.stderr &
	sudo $(ENV) dist/build/ch-delay-server/ch-delay-server s3 "$(TEST_NID):12345:34:3" 2> ch-delay-server2.stderr &
	../mero-halon/scripts/wait_contents 120 ch-delay-server.stderr ready \
		|| (sudo pkill ch-delay-server && false)
	../mero-halon/scripts/wait_contents 120 ch-delay-server2.stderr ready \
		|| (sudo pkill ch-delay-server && false)
	sudo $(ENV) dist/build/ch-delay-client/ch-delay-client "$(TEST_NID):12345:34:5" "$(TEST_NID):12345:34:2:10" "$(TEST_NID):12345:34:3:10" \
		|| (sudo pkill ch-delay-server && false)
	sudo pkill ch-delay-server

testtransport:
	sudo $(ENV) dist/build/testtransport/testtransport "0@lo:12345:34:2"

clean:
	$(CABAL) clean
	cd rpclite; make clean; cd ..
	sudo rm -rf m0.trace*
	sudo rm -rf *.db*
	sudo rm -rf *.stob
	sudo rm -rf *.o

ci: clean install haddock test

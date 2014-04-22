
ifndef MERO_ROOT
$(error The variable MERO_ROOT is undefined. Please, make it point to the mero build tree.)
endif

FF2C=$(MERO_ROOT)/xcode/ff2c/ff2c

#libdirs=$(MERO_ROOT)/xcode/ff2c/.libs\
#		$(MERO_ROOT)/net/test/.libs\
#		$(MERO_ROOT)/extra-libs/galois/src/.libs\
#		$(MERO_ROOT)/mero/.libs\
#		$(MERO_ROOT)/extra-libs/db4/build_unix\
#		$(MERO_ROOT)/extra-libs/cunit/CUnit/Sources/.libs\
#		$(MERO_ROOT)/ut/.libs

libdirs=$(MERO_ROOT)/mero/.libs\
        $(MERO_ROOT)/extra-libs/cunit/CUnit/Sources/.libs

empty=
sp=$(empty) $(empty)

ENV=LD_LIBRARY_PATH=$(subst $(sp),:,$(libdirs)) NTR_DB_DIR=$(NTR_DB_DIR)

LD_SEARCH_PATH=$(foreach dir,$(libdirs),-L$(dir))
HLD_SEARCH_PATH=$(foreach dir,$(libdirs),--extra-lib-dirs=$(dir))
EXTRAINCLUDE=--extra-include-dirs=$(MERO_ROOT) --extra-include-dirs=$(MERO_ROOT)/extra-libs/db4/build_unix --extra-include-dirs=$(MERO_ROOT)/extra-libs/cunit/CUnit/Headers --extra-include-dirs=$(MERO_ROOT)/extra-libs/yaml/include

#PROF_FLAGS=--enable-library-profiling --enable-executable-profiling
PROF_FLAGS=

#DEBUG_FLAGS=-f debug
DEBUG_FLAGS=

LDFLAGS=$(LD_SEARCH_PATH) -lmero
# -lgalois -lmero-ut -lmero-xcode-ff2c -lmero-net-test

CONFIGURE_FLAGS:=$(EXTRAINCLUDE) $(HLD_SEARCH_PATH) $(PROF_FLAGS) $(DEBUG_FLAGS)

build: configure
	cabal build
	make -C rpclite dummyService

install: build
	cabal copy
	cabal register

haddock: configure
	cabal haddock

configure: rpclite/rpclite_fop_ff.c rpclite/rpclite_fop_ff.h
	cabal configure --enable-tests $(CONFIGURE_FLAGS)

rpclite/rpclite_fop_ff.c: rpclite/rpclite_fop.ff
	$(FF2C) rpclite/rpclite_fop.ff

rpclite/rpclite_fop_ff.h: rpclite/rpclite_fop.ff
	$(FF2C) rpclite/rpclite_fop.ff

test: loadmero testnt testch testtransport

loadmero:
	sudo sysctl -w kernel.randomize_va_space=0
	sudo GENDERS=$(GENDERS) M0_CORE_DIR=$(MERO_ROOT) ./rpclite/st insmod

unloadmero:
	sudo GENDERS=$(GENDERS) M0_CORE_DIR=$(MERO_ROOT) ./rpclite/st rmmod

testrpcliteclient: build
	sudo $(ENV) dist/build/testrpclite/testrpclite

testrpcliteserver: build
	sudo $(ENV) dist/build/testrpclite/testrpclite -s

ghcich:
	sudo $(ENV) /opt/ghc/ghc-7.6.1.bin/bin/ghci tests/TestCH.hs -itests -i. -idist/build dist/build/rpclite/*.o $(LDFLAGS)

testnt: build
	sudo $(ENV) dist/build/TestNT/TestNT

testch: build
	sudo $(ENV) dist/build/TestCH/TestCH

testtutorial: build
	sudo $(ENV) dist/build/tutorial-server/tutorial-server "0@lo:12345:34:2" &
	sleep 30
	sudo $(ENV) dist/build/tutorial-client/tutorial-client "0@lo:12345:34:4" "0@lo:12345:34:2:0"
	sudo pkill tutorial-server

testchrpc: TEST_NID := $(shell sudo lctl list_nids | grep o2ib | head -1)
testchrpc: 
	sudo $(ENV) dist/build/ch-server/ch-server "$(TEST_NID):12345:34:2" > ch-server.stdout &
	../mero-ha/scripts/wait_contents 120 ch-server.stdout ready \
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
	../mero-ha/scripts/wait_contents 120 ch-delay-server.stderr ready \
		|| (sudo pkill ch-delay-server && false)
	../mero-ha/scripts/wait_contents 120 ch-delay-server2.stderr ready \
		|| (sudo pkill ch-delay-server && false)
	sudo $(ENV) dist/build/ch-delay-client/ch-delay-client "$(TEST_NID):12345:34:5" "$(TEST_NID):12345:34:2:10" "$(TEST_NID):12345:34:3:10" \
		|| (sudo pkill ch-delay-server && false)
	sudo pkill ch-delay-server

testtransport: build
	sudo $(ENV) dist/build/testtransport/testtransport "0@lo:12345:34:2"

clean:
	cabal clean
	cd rpclite; make clean; cd ..
	sudo rm -rf m0.trace*
	sudo rm -rf *.db*
	sudo rm -rf *.stob
	sudo rm -rf *.o

ci: clean install haddock test

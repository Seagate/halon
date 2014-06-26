# Copyright : (C) 2013 Xyratex Technology Limited.
# License   : All rights reserved.

# This Makefile is DEPRECATED. It should not be called recursively.
#
# If there are any required targets, they should be moved to the toplevel
# Makefile, or to be called as a part of setup / test run.

# Make TCP the default. Can be overriden on the command line or in
# mk/config.mk.
export USE_TCP = true
export USE_RPC =

MYPWD = $(shell pwd)

# Make USE_TCP and USE_RPC mutually exclusive.
ifdef USE_TCP
USE_RPC =
endif

ifdef USE_RPC
USE_TCP =
endif

DEBUG =

# Allow above defaults to be overriden by using a local config file.
# That file MUST NOT BE CHECKED IN. Its content is local, not global.
-include mk/config.mk

ifndef MERO_ROOT
$(error The variable MERO_ROOT is undefined. Please, make it point to the mero build tree or set to -- to work without mero.)
endif

ifneq ($(MERO_ROOT),--)
empty :=
space := $(empty) $(empty)
export LD_LIBRARY_PATH := \
	$(subst $(space),:,$(strip \
		$(MERO_ROOT)/mero/.libs\
		$(MERO_ROOT)/extra-libs/cunit/CUnit/Sources/.libs\
		$(MERO_ROOT)/extra-libs/galois/src/.libs\
                $(LD_LIBRARY_PATH)))
SUDO = sudo -E LD_LIBRARY_PATH=$(LD_LIBRARY_PATH)
else
SUDO =
endif

ifdef USE_TCP
TEST_LISTEN = 127.0.0.1:8090
endif

ifdef USE_RPC
# -E to Preserve environment. Still need to pass LD_LIBRARY_PATH
# explicitly because most operating systems reset that environment
# variable for setuid binaries.
TEST_NID = `sudo lctl list_nids | grep o2ib | head -1`
TEST_LISTEN = $(TEST_NID):12345:34:1
CABAL_FLAGS += -frpc

RPCLITE_PREFIX=$(shell pwd)/../network-transport-rpc/rpclite

libdirs=$(MERO_ROOT)/mero/.libs \
        $(MERO_ROOT)/extra-libs/cunit/CUnit/Sources/.libs

HLD_SEARCH_PATH=$(foreach dir,$(libdirs),--extra-lib-dirs=$(dir))

CABAL_FLAGS += --extra-include-dirs=$(MERO_ROOT) --extra-include-dirs=$(MERO_ROOT)/extra-libs/db4/build_unix $(HLD_SEARCH_PATH) --extra-include-dirs=$(RPCLITE_PREFIX)
endif

ifdef DEBUG
CABAL_FLAGS += -fdebug --enable-tests
endif
CABAL = cabal $(CABAL_SANDBOX)

# This variable is required to be set on the command line or in the
# environment. As such, this variable does not need to be exported
# explicitly, but is available in the environment of recipes.
export GENDERS

build: configure
	$(CABAL) build

install: build
	$(CABAL) copy
	$(CABAL) register

test: build testepoch testhastate
	make loadmero
# XXX: Tests for this project will not be compiled under ghc-7.8
# because tests are failing. This workaround should be removed
# as soon as issue will be fixed.
	if [ -f dist/build/unit-tests/unit-tests ] ; then \
	$(SUDO) dist/build/unit-tests/unit-tests --num-threads 1 -- $(TEST_LISTEN); \
	fi
	if [ -f dist/build/integration-tests/integration-tests ] ; then \
	$(SUDO) dist/build/integration-tests/integration-tests --num-threads 1 -- $(TEST_LISTEN); \
	fi

ifdef USE_RPC
testepoch:
	make loadmero
	tests/wrapper $(SUDO) PATH=$(MYPWD)/scripts:$(PATH):$(LD_LIBRARY_PATH) ../dist/build/testepoch/testepoch $(TEST_NID)
	$(SUDO) pkill m0d || true

testhastate:
	sudo -E $(ENV) $(RPCLITE_PREFIX)/st sstart confd
	make -C hastate dummy_mero || \
		($(SUDO) -E $(ENV) $(RPCLITE_PREFIX)/st sstop confd && false)
	$(SUDO) -E $(ENV) hastate/call_dummy_mero.sh $(TEST_NID):12345:34:2 $(TEST_NID):12345:34:1 $(TEST_NID):12345:34:3 || \
		($(SUDO) -E $(ENV) $(RPCLITE_PREFIX)/st sstop confd && false)
	scripts/wait_contents 120 dummy_mero.stdout ready || \
		($(SUDO) kill `cat dummy_mero.pid`; $(SUDO) -E $(ENV) $(RPCLITE_PREFIX)/st sstop confd && false)
	$(SUDO) -E $(ENV) dist/build/testhastate/testhastate $(TEST_NID):12345:34:3 $(TEST_NID):12345:34:2 || \
		($(SUDO) kill `cat dummy_mero.pid`; $(SUDO) -E $(ENV) $(RPCLITE_PREFIX)/st sstop confd && false)
	$(SUDO) kill `cat dummy_mero.pid`; $(SUDO) -E $(ENV) $(RPCLITE_PREFIX)/st sstop confd
else
testepoch:
testhastate:
endif

haddock: configure
	$(CABAL) haddock

dep:
	-$(CABAL) install --enable-tests --only-dependencies

configure: dep
	$(CABAL) configure $(CABAL_FLAGS)

halon-node-agent:
	$(SUDO) scripts/halon node-agent

halon-station:
	$(SUDO) scripts/halon station $(ARGS)

clean: cleanglobaldb cleanlocaldb clean_hastate
	$(CABAL) clean
	rm -rf dummy_mero.stdout
	rm -rf dummy_mero.pid

ifneq ($(MERO_ROOT),--)
clean_hastate:
	make -C hastate clean

cleanlocaldb:
	${SUDO} rm -rf m0.trace.* *rpclite.db* *rpclite2* tmp-HA*

cleanglobaldb:
	${SUDO} rm -rf /var/mero/*
	${SUDO} mkdir /var/mero/addb-stobs /var/mero/db /var/mero/stobs

loadmero:
	$(SUDO) sysctl -w kernel.randomize_va_space=0
	$(SUDO) M0_CORE_DIR=$(MERO_ROOT) ../network-transport-rpc/rpclite/st insmod

unloadmero:
	$(SUDO) M0_CORE_DIR=$(MERO_ROOT) ../network-transport-rpc/rpclite/st rmmod
else
clean_hastate:
cleanlocaldb:
cleanglobaldb:
loadmero:
unloadmero:
endif

ci: clean install haddock test

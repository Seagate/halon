# Copyright : (C) 2013 Xyratex Technology Limited.
# License   : All rights reserved.

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
endif

ifdef DEBUG
CABAL_FLAGS += -fdebug --enable-tests
endif

# This variable is required to be set on the command line or in the
# environment. As such, this variable does not need to be exported
# explicitly, but is available in the environment of recipes.
export GENDERS

build: configure
	cabal build

install: build
	cabal copy
	cabal register

.PHONY: test loadmero build testidentify ut it

test: loadmero build testidentify ut it

ut:
	$(SUDO) dist/build/unit-tests/unit-tests --num-threads 1 -- $(TEST_LISTEN)

it:
	$(SUDO) dist/build/integration-tests/integration-tests --num-threads 1 -- $(TEST_LISTEN)

ifdef USE_RPC
testidentify:
	$(SUDO) dist/build/testidentify/testidentify $(TEST_NID)

loadmero:
	$(SUDO) sysctl -w kernel.randomize_va_space=0
	$(SUDO) M0_CORE_DIR=$(MERO_ROOT) ../network-transport-rpc/rpclite/st insmod

unloadmero:
	$(SUDO) M0_CORE_DIR=$(MERO_ROOT) ../network-transport-rpc/rpclite/st rmmod

else
testidentify:
loadmero:
endif

haddock: configure
	cabal haddock


sandbox: 
	cabal sandbox init --sandbox=$(SANDBOX)
	cabal sandbox add-source \
		../replicated-log
	cabal install --only-dependencies --enable-tests --reorder-goals || echo "not installing"

configure: sandbox
	cabal configure $(CABAL_FLAGS)

clean:
	cabal clean

ci: clean install haddock test

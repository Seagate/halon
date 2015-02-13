####################################################################
#
# Halon project's Makefile
#
# None of the targets install and/or touch files outside of the
# top-level directory, dependencies and build results are installed
# into the local cabal sandbox in .cabal-sandbox.
#
# Targets available:
#
#   * project build:
#       build  [default]  -- build, test and install all subprojects
#       clean             -- clean sub-projects and unregister them
#
#   * dependencies:
#       dep               -- install all Haskell dependencies
#       depclean          -- remove the sandbox altogether
#
# Variables that affect the build process:
#
#    MERO_ROOT            -- path to the build-directory of the mero project
#    USE_MERO							-- use real mero (requires mero)
#    USE_RPC              -- use rpc communication (require mero)
#    USE_TCP              -- use TCP communication (default)
#
#    NO_TESTS             -- do not run tests while building packages
#    CABAL_FLAGS          -- flags passed to the cabal
#    PACKAGES             -- sub-projects to work with (see README.md!)
#
# * Packages Makefiles
#
#   All package-level Makefiles are deprecated and are not called
#   recursively. However some of the packages still contain Makefiles,
#   because there are complicated targets that are not run from the
#   top-level Makefile. All this functionality should be moved to the
#   top-level Makefile or a custom setup, but until then, old
#   Makefiles can be used.

# Permanent local overrides go here, to avoid having to specify them
# each time on the command line. Please DO NOT check in this file.
-include mk/local.mk

ifdef USE_TCP
USE_RPC =
endif

ifdef USE_RPC
USE_RPCLITE = true
USE_TCP =
endif

ifdef USE_MERO
USE_RPCLITE = true
endif

# Global configuration variables.
include mk/config.mk

# The DELETE_ON_ERROR behavior is used in the `make dep` logic, since
# we use the cabal.sandbox.config file as a stamp file on whether the
# sandbox creation was successful.
.DELETE_ON_ERROR:

all: build

ifdef USE_RPCLITE

ifndef MERO_ROOT
$(error The variable MERO_ROOT is undefined. Please, make it point to the mero build tree.)
endif

empty :=
space := $(empty) $(empty)
export LD_LIBRARY_PATH := \
	$(subst $(space),:,$(strip \
		$(MERO_ROOT)/mero/.libs\
                $(LD_LIBRARY_PATH)))

RPCLITE_PREFIX=$(shell pwd)/rpclite/rpclite

libdirs=$(MERO_ROOT)/mero/.libs

HLD_SEARCH_PATH=$(foreach dir,$(libdirs),--extra-lib-dirs=$(dir))

override CABAL_FLAGS += --extra-include-dirs=$(MERO_ROOT) $(HLD_SEARCH_PATH) --extra-include-dirs=$(RPCLITE_PREFIX)
endif

ifdef USE_MERO
override CABAL_FLAGS += -fmero
endif

ifdef USE_RPC
TEST_NID = $(shell sudo lctl list_nids | head -1)
TEST_LISTEN = $(TEST_NID):12345:34:1
override CABAL_FLAGS += -frpc
else
USE_TCP = 1
TEST_LISTEN = 127.0.0.1:8090
endif

ifdef DEBUG
override CABAL_FLAGS += -fdebug
endif

ifdef USE_RPC
# -E to Preserve environment. Still need to pass LD_LIBRARY_PATH
# explicitly because most operating systems reset that environment
# variable for setuid binaries.
SUDO = sudo -E LD_LIBRARY_PATH=$(LD_LIBRARY_PATH)
override CABAL_FLAGS += --extra-include-dirs=$(MERO_ROOT) --extra-lib-dirs=$(MERO_ROOT)/mero/.libs
else
SUDO =
endif

# This variable is required to be set on the command line or in the
# environment. As such, this variable does not need to be exported
# explicitly, but is available in the environment of recipes.
export GENDERS

ifndef NO_TESTS
CABAL_BUILD_JOBS = --jobs=1
override CABAL_FLAGS += --run-tests
endif

export USE_TCP
export USE_RPC
export USE_RPCLITE
export USE_MERO
export TEST_LISTEN

.PHONY: ci
ci: cabal.config build
	./scripts/check-copyright.sh

.PHONY: build
build: dep
# XXX Tests tend to bind the same ports, making them mutually
# exclusive in time. The solution is to allow tests to bind
# a random available port.
	cabal install $(CABAL_FLAGS) $(CABAL_BUILD_JOBS) $(PACKAGES)

CLEAN := $(patsubst %,%_clean,$(PACKAGES))
.PHONY: $(CLEAN) clean depclean
$(CLEAN):
	-cd $(patsubst %_clean, %, $@) && $(SUDO) cabal clean
	-cabal sandbox hc-pkg -- unregister $(patsubst %_clean, %, $@) --force
clean: $(CLEAN)
depclean:
	rm -rf .cabal-sandbox
	rm -f cabal.sandbox.config

.PHONY: dep
dep: cabal.sandbox.config
cabal.sandbox.config: mk/config.mk
	@echo "Initializing sandbox"
	cabal sandbox init
	cabal sandbox add-source $(addprefix $(VENDOR_DIR),$(VENDOR_PACKAGES)) \
                                 $(addprefix $(CEP_DIR),$(CEP_PACKAGES)) \
	                         $(addprefix $(PACKAGE_DIR),$(PACKAGES))
# Using --reinstall to override packages from GHC global db.
	cabal install --reorder-goals --reinstall $(VENDOR_PACKAGES)
	cabal install --only-dependencies --reorder-goals $(CABAL_FLAGS) $(PACKAGES)

# Updating cabal.config should only ever be done manually, i.e. explicitly
# through listing freeze as a goal, not implicitly as part of another rule.
# This is why cabal.config is not listed as the target of this rule, even
# though it is a product of the recipe.
.PHONY: freeze
freeze:
	(cd mero-halon; cabal freeze --reorder-goals)
	mv mero-halon/cabal.config cabal.config

# This target will generate a distributable RPM based on the
# current checkout.
# It will generate a binary RPM in ./rpmbuild/RPMS/x86_64
# and a pseudo-source tar in ./rpmbuild/SRPMS
rpm: build
	mkdir -p rpmbuild/SOURCES
	cp .cabal-sandbox/bin/halond rpmbuild/SOURCES/
	cp .cabal-sandbox/bin/halonctl rpmbuild/SOURCES/
	rpmbuild --define "_topdir ${PWD}/rpmbuild" -ba rpmbuild/SPECS/halon.spec


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

ifdef USE_TCP
USE_RPC =
endif

ifdef USE_RPC
USE_TCP =
endif

# Global configuration variables.
include mk/config.mk

# Permanent local overrides go here, to avoid having to specify them
# each time on the command line. Please DO NOT check in this file.
-include mk/local.mk

# The DELETE_ON_ERROR behavior is used in the `make dep` logic, since
# we use the cabal.sandbox.config file as a stamp file on whether the
# sandbox creation was successful.
.DELETE_ON_ERROR:

all: build

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
else
USE_TCP = 1
TEST_LISTEN = 127.0.0.1:8090
endif

ifdef DEBUG
CABAL_FLAGS += -fdebug
endif

# Borrowed from halon Makefile
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

# This variable is required to be set on the command line or in the
# environment. As such, this variable does not need to be exported
# explicitly, but is available in the environment of recipes.
export GENDERS

ifndef NO_TESTS
CABAL_FLAGS += --run-tests
endif

export USE_TCP
export USE_RPC
export TEST_LISTEN

.PHONY: build
build: dep
	cabal install $(PACKAGES) \
	              $(filter-out --jobs=%,$(CABAL_FLAGS)) --jobs=1

CLEAN := $(patsubst %,%_clean,$(PACKAGES))
.PHONY: $(CLEAN) clean depclean
$(CLEAN):
	-cd $(patsubst %_clean, %, $@) && cabal clean
	-cabal sandbox hc-pkg -- unregister $(patsubst %_clean, %, $@) --force
clean: $(CLEAN)
depclean:
	cabal sandbox delete

.PHONY: dep
dep: cabal.sandbox.config
cabal.sandbox.config: mk/config.mk
	@echo "Initializing sandbox"
	cabal sandbox init
	cabal sandbox add-source $(addprefix $(VENDOR_DIR),$(VENDOR_PACKAGES)) \
	                         $(addprefix $(PACKAGE_DIR),$(PACKAGES))
# Using --reinstall to override packages from GHC global db.
	cabal install --reorder-goals --reinstall $(VENDOR_PACKAGES)
	cabal install --only-dependencies --reorder-goals $(CABAL_FLAGS) $(PACKAGES)

# This target will generate distributable packages based on the
# checked-in master branch of this repository. It will generate
# a binary RPM in ./rpmbuild/RPMS/x86_64 and a source tar in
# ./rpmbuild/SOURCES
.PHONY: rpm-checkout rpm-build
rpm:
ifeq ($(shell locale -a | grep -Fixc "$(HA_BUILD_LANG)"), 0)
		$(error $(HA_BUILD_LANG) not present; please set HA_BUILD_LANG to an appropriate locale.)
endif
	echo "%_topdir   $(RPMROOT)" > ~/.rpmmacros
	echo "%_tmppath  %{_topdir}/tmp" >> ~/.rpmmacros
	mkdir -p $(RPMROOT)/SOURCES
	(cd $(RPMROOT)/SOURCES && \
	 rm -rf halon halon.tar.gz && \
         git clone --branch $(RPMBRANCH) ../.. halon && \
         tar --exclude-vcs -czf halon.tar.gz halon)
	(cd $(RPMROOT)/SPECS && \
        HA_BUILD_LANG=$(HA_BUILD_LANG) rpmbuild -ba halon.spec)

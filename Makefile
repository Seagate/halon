####################################################################
#
#
# Make halon project
#
# Targets available:
#
#   * project build:
#       build  [default]  -- build all subprojects inside a sandboxes [1]
#       clean             -- unregister subprojects from local sandbox
#       ci                -- clear all projects and then build and test
#                            then
#   * dependencies:
#       sandbox           -- prepare sandboxes
#       dep               -- install all Haskell dependencies,
#                            mero will not be installed even if it's 
#                            required
#       depclean          -- remove sandboxes with all dependencies
#
# -- 
# [1] Due to cabal problems build implies test of all built packages
#
# Variables that affects installation process:
#
#    MERO_ROOT            -- path to the build-directory of the mero
#                            project
#    USE_RPC              -- use rpc communication (require mero)
#    USE_TCP              -- use TCP communication
#    
#    SUPPRESS_TESTS       -- do not run tests while building packages
#    CABAL_FLAGS          -- flags passed to the cabal
#    PACKAGES             -- projects to work with
#
# * Multiple jobs
#
#   If cabal is run with --jobs argument it attempts to run tests in
#   parallel. This leads to interfere between integration and
#   unit tests for some of the projects. As a result reduce a number
#   of parallel tasks to 1 during the installation.
#
#   The failing packages are:
#      * halon
#      * mero-halon
#
#   So scheduler sandbox may work without this hack.
#
# * Packages Makefiles
#
#   All package-level Makefiles are deprecated and do not called
#   recursively. However some of the packages still contain Makefiles, 
#   this is done because there are a complicated targets that are not
#   run from the top level makefile. All this functionality should be moved
#   to the top level Makefile or custom setup, but until it will be done
#   old Makefiles can be used.

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

ifndef SUPPRESS_TESTS
CABAL_FLAGS += --run-tests
endif

export USE_TCP
export USE_RPC
export RANDOMIZED_TESTS
export TEST_LISTEN


# See section about jobs in the top of the file
.PHONY: build-generic build-default build-random build
build-default: SANDBOX_CONFIG = $(SANDBOX_DEFAULT_CONFIG)
build-default: BUILDDIR = dist
build-default:
	cabal --sandbox-config-file=$(SANDBOX_CONFIG) \
	      install $(PACKAGES) $(filter-out --jobs=%,$(CABAL_FLAGS)) \
	              --jobs=1 \
	              --builddir=$(BUILDDIR)

build-random:  SANDBOX_CONFIG = $(SANDBOX_SCHED_CONFIG)
build-random:  CABAL_FLAGS += -fuse-scheduler -frandomTests
build-random:  BUILDDIR = dist-scheduler
build-random:
	if [ -n "$(filter-out $(NON_SCHED),$(PACKAGES))" ] ; then \
	cabal --sandbox-config-file=$(SANDBOX_CONFIG) \
	      install $(filter-out $(NON_SCHED),$(PACKAGES)) \
	              $(filter-out --jobs=%,$(CABAL_FLAGS)) \
	              --builddir=$(BUILDDIR) ; \
	fi
build: build-random build-default


CLEAN := $(patsubst %,%_clean,$(PACKAGES))
CLEAN_SCHED := $(patsubst %, %_clean_sched, $(filter-out $(NON_SCHED), $(PACKAGES)))


$(CLEAN):
	-cabal --sandbox-config-file=$(SANDBOX_DEFAULT_CONFIG) \
	      sandbox hc-pkg -- unregister $(patsubst %_clean, %, $@) \
	      --force

$(CLEAN_SCHED):
	-cabal --sandbox-config-file=$(SANDBOX_SCHED_CONFIG) \
	      sandbox hc-pkg -- unregister $(patsubst %_clean_sched, %, $@) \
	      --force

clean: $(CLEAN) $(CLEAN_SCHED)

depclean:
# XXX The command
#
#     $ cabal sandox delete ...
#
# currently fails when sandbox config file is in "non-default location".
	rm -rf $(SANDBOX_DEFAULT) \
	       $(SANDBOX_SCHED) \
	       $(SANDBOX_DEFAULT_CONFIG) \
	       $(SANDBOX_SCHED_CONFIG)

$(SANDBOX_DEFAULT_CONFIG): SANDBOX_DIR = $(SANDBOX_DEFAULT)
$(SANDBOX_SCHED_CONFIG):   SANDBOX_DIR = $(SANDBOX_SCHED)
$(SANDBOX_DEFAULT_CONFIG) $(SANDBOX_SCHED_CONFIG):   
	@echo "Initializing sandbox ($@)"
	cabal sandbox init --sandbox=$(SANDBOX_DIR)
	cabal sandbox add-source $(addprefix $(VENDOR_DIR),$(VENDOR_PACKAGES)) \
	                         $(addprefix $(PACKAGE_DIR),$(PACKAGES))
	mv cabal.sandbox.config $@
sandbox: $(SANDBOX_DEFAULT_CONFIG) $(SANDBOX_SCHED_CONFIG)

dep-default: SANDBOX_CONFIG = $(SANDBOX_DEFAULT_CONFIG)
dep-default:
	cabal --sandbox-config-file=$(SANDBOX_CONFIG) \
	      install --enable-tests \
                      --only-dependencies $(CABAL_FLAGS)\
                      --reorder-goals $(PACKAGES)
dep-random: SANDBOX_CONFIG = $(SANDBOX_SCHED_CONFIG)
dep-random:
	cabal --sandbox-config-file=$(SANDBOX_CONFIG) \
	      install --enable-tests \
                      --only-dependencies $(CABAL_FLAGS)\
                      --reorder-goals $(PACKAGES)
dep: sandbox dep-default dep-random

ci: clean build

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

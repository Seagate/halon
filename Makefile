# Global configuration variables.
include mk/config.mk

# Permanent local overrides go here, to avoid having to specify them
# each time on the command line. Please DO NOT check in this file.
-include mk/local.mk

all: install

# Error-hiding.
#
# Some recipes of the 'sandbox' target in subprojects ignore the
# return code of cabal. This is done on purpose, as it's not possible
# to successfully run --dependencies-only if reverse dependencies of
# the package exist in the sandbox, and it is not possible to
# forfully reinstall the package without forcing installation of all
# its dependencies even when unneeded.
#
# In this cases, ignoring the return code of cabal allows the recipe
# to proceed when the package is already installed in the sandbox.
# The tradeoff is that in case of a reinstallation failure involving
# dependencies, cabal will fail on the subsequent configure phase.
#
# Also there are cases when package reinstalls lead to dependency
# breakage and cabal doesn't immediately fixes them, this case is not
# covered by existsing 'depdenency' model, in order to fix them we
# need to introduce a way to properly check state of dependencies and
# reinstall them if needed.

# The following code snippet allowes us to run specified target in
# all sub-projects. By setting TARGET variable and calling the deepest
# rule, that effectivelly lead to invoking rule in all projects.
# `ci' is the continuous integration target.
.PHONY: ci clean install test
clean: TARGET = clean
test:  TARGET = test
install: TARGET = install
ci: TARGET = ci
clean: mero-halon
	rm -rf $(SANDBOX_DEFAULT) \
	       $(SANDBOX_SCHED) \
	       $(SANDBOX_DEFAULT_CONFIG) \
	       $(SANDBOX_SCHED_CONFIG)

ci test install: mero-halon

$(SANDBOX_DEFAULT_CONFIG): SANDBOX_DIR = $(SANDBOX_DEFAULT)
$(SANDBOX_SCHED_CONFIG):   SANDBOX_DIR = $(SANDBOX_SCHED)

$(SANDBOX_DEFAULT_CONFIG) $(SANDBOX_SCHED_CONFIG):
	@echo "Initializing sandbox ($@)"
	cabal sandbox init --sandbox=$(SANDBOX_DIR)
	cabal sandbox add-source $(VENDOR_PACKAGES) $(PACKAGES)
	cabal install --enable-tests \
                      --only-dependencies $(CABAL_FLAGS)\
                      --reorder-goals $(PACKAGES)
	mv cabal.sandbox.config $@

.PHONY: dep
dep: $(SANDBOX_DEFAULT_CONFIG) $(SANDBOX_SCHED_CONFIG)

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

.PHONY: network-transport-rpc confc halon
network-transport-rpc confc halon mero-halon: $(NTR_DB_DIR)
	make -C $@ SANDBOX=$(SANDBOX_DEFAULT) CABAL_SANDBOX=$(CABAL_DEFAULT_SANDBOX) DEBUG=true $(TARGET)

.PHONY: distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log
distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log:
	@echo "Running $(TARGET) for $@ with default sandbox"
	make -C $@ CABAL_SANDBOX=$(CABAL_DEFAULT_SANDBOX) $(TARGET)
	@echo "Running $(TARGET) for $@ with scheduler sandbox"
	make -C $@ CABAL_SANDBOX=$(CABAL_SCHED_SANDBOX) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: distributed-process-scheduler
distributed-process-scheduler: distributed-process-trans
	@echo "Running $(TARGET) for $@ with default sandbox"
	make -C $@ CABAL_SANDBOX=$(CABAL_DEFAULT_SANDBOX) $(TARGET)
	echo "Running $(TARGET) for $@ with scheduler sandbox"
	make -C $@ CABAL_SANDBOX=$(CABAL_SCHED_SANDBOX) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: $(NTR_DB_DIR)
ifneq ($(MERO_ROOT),--)
$(NTR_DB_DIR):
	sudo rm -rf $@
	mkdir $@
else
$(NTR_DB_DIR):
endif

mero-halon: halon
halon: replicated-log
ifdef USE_RPC
halon: network-transport-rpc confc
endif
replicated-log:  distributed-process-test consensus consensus-paxos
consensus-paxos: distributed-process-test consensus
consensus: distributed-process-scheduler

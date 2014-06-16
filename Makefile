# Global configuration variables.
include mk/config.mk

# Permanent local overrides go here, to avoid having to specify them
# each time on the command line. Please DO NOT check in this file.
-include mk/local.mk

all: install

# Error-hiding.
#
# Some subprojects has error hiding code in their snippets in 'sandbox'
# target. This is done for purpose, as it's not possible either to run
# --denendencies-only it the package that reverse dependencies in same
# sandbox or reinstall package without forcing reinstall on all it's
# dependencies. This error hiding allow to continue installation in
# case when package already correctly installed in a sandbox.
# The tradeoff is that if case of reinstall failure cabal will fail on
# the configure phase not sandbox.
# Also there are exists cases when package reinstall leads to dependency
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
	rm -rf $(SANDBOX_DEFAULT)
	rm -rf $(SANDBOX_SCHED_DB)

ci test install: mero-halon

dep:
	@echo "Building dependencies sandboxes"
	cabal sandbox init --sandbox=$(SANDBOX_DEFAULT)
	cabal sandbox add-source $(ROOT_DIR)/vendor/distributed-process
#	cabal sandbox add-source $(ROOT_DIR)/vendor/distributed-static
#	cabal sandbox add-source $(ROOT_DIR)/vendor/network-transport
#	cabal sandbox add-source $(ROOT_DIR)/vendor/network-transport-tcp
#	cabal sandbox add-source $(ROOT_DIR)/vendor/rank1dynamic
	cabal install --enable-tests \
                      --only-dependencies $(CABAL_FLAGS) \
                      --reorder-goals $(ROOT_DIR)/distributed-process-scheduler/ \
                                      $(ROOT_DIR)/distributed-process-test/ \
                                      $(ROOT_DIR)/distributed-process-trans/ \
                                      $(ROOT_DIR)/consensus/ \
                                      $(ROOT_DIR)/consensus-paxos/ \
                                      $(ROOT_DIR)/replicated-log/ \
                                      $(ROOT_DIR)/network-transport-rpc/ \
                                      $(ROOT_DIR)/confc/ \
                                      $(ROOT_DIR)/halon/ \
                                      $(ROOT_DIR)/mero-halon/
	@echo "Preparing scheduler sandbox"
	rm -rf $(SANDBOX_SCHED_DB)
	mkdir -p $(SANDBOX_SCHED_DB)
	cp -r $(SANDBOX_DEFAULT_DB)/* $(SANDBOX_SCHED_DB)

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
	make -C $@ SANDBOX=$(SANDBOX_DEFAULT) DEBUG=true $(TARGET)

.PHONY: distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log
distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log: $(SANDBOX_SCHED_DB)
	@echo "Running $(TARGET) for $@ with default sandbox"
	make -C $@ SANDBOX=$(SANDBOX_DEFAULT) $(TARGET)
	@echo "Running $(TARGET) for $@ with default sandbox"
	make -C $@ SANDBOX=$(SANDBOX_SCHED) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: distributed-process-scheduler
distributed-process-scheduler: $(SANDBOX_SCHED_DB) distributed-process-trans
	@echo "Running $(TARGET) for $@ with default sandbox"
	make -C $@ SANDBOX=$(SANDBOX_DEFAULT) $(TARGET)
	echo "Running $(TARGET) for $@ in scheduler sandbox"
	make -C $@ SANDBOX=$(SANDBOX_SCHED) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: $(SANDBOX_SCHED_DB)
$(SANDBOX_SCHED_DB):

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

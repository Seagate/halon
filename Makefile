# Global configuration variables.
include mk/config.mk

# Permanent local overrides go here, to avoid having to specify them
# each time on the command line. Please DO NOT check in this file.
-include mk/local.mk

# `ci' is the continuous integration target.
.PHONY: ci clean install
clean: TARGET = clean
install: TARGET = install
ci: TARGET = ci
ci clean install: mero-ha

dep:
	cabal sandbox init --sandbox=$(SANDBOX_DEFAULT)
	cabal sandbox add-source $(ROOT_DIR)/vendor/distributed-process/distributed-process
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
                                      $(ROOT_DIR)/ha/ \
                                      $(ROOT_DIR)/mero-ha/

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

.PHONY: network-transport-rpc confc ha
network-transport-rpc confc ha mero-ha: $(NTR_DB_DIR)
	make -C $@ SANDBOX=$(SANDBOX_DEFAULT) DEBUG=true $(TARGET)

.PHONY: distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log
distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log: $(SANDBOX_SCHED_DB)
	make -C $@ SANDBOX=$(SANDBOX_DEFAULT) $(TARGET)
	make -C $@ SANDBOX=$(SANDBOX_SCHED) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: distributed-process-scheduler
distributed-process-scheduler: $(SANDBOX_SCHED_DB) distributed-process-trans
	make -C $@ SANDBOX=$(SANDBOX_DEFAULT) $(TARGET)
	make -C $@ SANDBOX=$(SANDBOX_SCHED) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: $(SANDBOX_SCHED_DB)
$(SANDBOX_SCHED_DB):
	rm -rf $(SANDBOX_SCHED_DB)
	mkdir -p $(SANDBOX_SCHED_DB)
	cp -r $(SANDBOX_DEFAULT_DB)/* $(SANDBOX_SCHED_DB)

.PHONY: $(NTR_DB_DIR)
ifneq ($(MERO_ROOT),--)
$(NTR_DB_DIR):
	sudo rm -rf $@
	mkdir $@
else
$(NTR_DB_DIR):
endif

mero-ha: ha
ha: replicated-log
ifdef USE_RPC
ha: network-transport-rpc confc
endif
replicated-log:  distributed-process-test consensus consensus-paxos
consensus-paxos: distributed-process-test consensus
consensus: distributed-process-scheduler

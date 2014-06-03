# Global configuration variables.
include mk/config.mk

# Permanent local overrides go here, to avoid having to specify them
# each time on the command line. Please DO NOT check in this file.
-include mk/local.mk

# Continuous integration target.
.PHONY: ci clean install

clean: TARGET = clean
install: TARGET = install
ci: TARGET = ci
ci clean install: mero-ha

dep:
	cabal sandbox init --sandbox=$(SANDBOX_DEFAULT)
	cabal sandbox add-source vendor/distributed-process/distributed-process
	cabal install --enable-tests --only-dependencies $(CABAL_FLAGS) --reorder-goals distributed-process-scheduler/ distributed-process-test/ distributed-process-trans/ consensus/ consensus-paxos/ replicated-log/ network-transport-rpc/ confc/ ha/ mero-ha/

# This target will generate distributable packages based on
# the checked-in master branch of this repository.
# It will generate a binary RPM in ./rpmbuild/RPMS/x86_64
# and a source tar in ./rpmbuild/SOURCES
rpm:
	echo "%_topdir   $(RPMROOT)" > ~/.rpmmacros
	echo "%_tmppath  %{_topdir}/tmp" >> ~/.rpmmacros
	cd $(RPMROOT)/SOURCES && rm -rf eiow-ha eiow-ha.tar.gz && git clone --branch $(RPMBRANCH) ../.. eiow-ha && tar --exclude-vcs -czf eiow-ha.tar.gz eiow-ha
	cd $(RPMROOT)/SPECS && rpmbuild -ba eiow-ha.spec

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

# The genders file to use for the CI target.
ifndef GENDERS
GENDERS = $(shell pwd)/mero-ha/scripts/genders-parsci
export GENDERS
endif
RPMROOT = $(shell pwd)/rpmbuild

# The git branch of this repository whose HEAD will
# serve as the basis of RPM packaging.
RPMBRANCH = master

# DB file directory for Mero used by network-transport-rpc
# CAUTION: This path will be removed by superuser.
ifndef NTR_DB_DIR
NTR_DB_DIR = $(shell pwd)/testdb
export NTR_DB_DIR
endif

empty=
sp=$(empty) $(empty)
USER_DB=$(subst :,,$(shell cabal sandbox hc-pkg list | grep "/package" | tail -1))

GHC_VERSION = $(shell ghc --numeric-version)

SANDBOX_REGULAR = $(shell pwd)/.cabal-sandbox

SANDBOX_SCHED = $(shell pwd)/.cabal-sandbox-scheduler
SANDBOX_SCHED_DB = $(SANDBOX_SCHED)/packages-$(GHC_VERSION).conf

# Continuous integration target.
.PHONY: ci clean install
clean: TARGET = clean
install: TARGET = install
ci: TARGET = ci
ci clean install: mero-ha

dep:
	cabal sandbox init --sandbox=$(SANDBOX_REGULAR)
	cabal install --enable-tests --only-dependencies distributed-process-platform/ distributed-process-scheduler/ distributed-process-test/ distributed-process-trans/ consensus/ consensus-paxos/ replicated-log/ network-transport-rpc/ confc/ ha/ mero-ha/
	cabal install distributed-process-platform

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
	make -C $@ SANDBOX=$(SANDBOX_REGULAR) DEBUG=true $(TARGET)

.PHONY: distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log
distributed-process-test distributed-process-trans consensus consensus-paxos replicated-log: $(SANDBOX_SCHED_DB)
	make -C $@ SANDBOX=$(SANDBOX_REGULAR) $(TARGET)
	make -C $@ SANDBOX=$(SANDBOX_SCHED) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: distributed-process-scheduler
distributed-process-scheduler: $(SANDBOX_SCHED_DB) distributed-process-trans
	make -C $@ SANDBOX=$(SANDBOX_REGULAR) $(TARGET)
	make -C $@ SANDBOX=$(SANDBOX_SCHED) RANDOMIZED_TESTS=1 $(TARGET)

.PHONY: $(SANDBOX_SCHED_DB)
$(SANDBOX_SCHED_DB):
	rm -rf $(SANDBOX_SCHED_DB)
	mkdir -p $(SANDBOX_SCHED_DB)
	cp -r $(USER_DB)/* $(SANDBOX_SCHED_DB)

.PHONY: $(NTR_DB_DIR)
$(NTR_DB_DIR):
	rm -rf $@
	mkdir $@

mero-ha: ha
ha: replicated-log
ifdef USE_RPC
ha: network-transport-rpc confc
endif
replicated-log:  distributed-process-test consensus consensus-paxos
consensus-paxos: distributed-process-test consensus
consensus: distributed-process-scheduler

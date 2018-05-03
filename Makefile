# This project uses The Stack build tool. Please refer to the README
# for build instructions.

GITREV          := git$(shell git rev-parse --short HEAD)
# assume the first part of `git describe` is a tag in format 'n.m'
VERSION         := $(shell git describe | cut -f1 -d-)
GHC_OPTIONS     := -g -j4
DIST_FILE       := halon-$(VERSION).tar.gz
M0_SRC_DIR      := /usr/include/mero
MOCK_CONFIG     := $(M0_SRC_DIR)/mero-mock.cfg
RPMBUILD_FLAGS  :=
RPMBUILD_DIR    := $(HOME)/rpmbuild
RPMBUILD_TOPDIR := $(abspath $(RPMBUILD_DIR))
RPMSOURCES_DIR  := $(RPMBUILD_DIR)/SOURCES
RPMSPECS_DIR    := $(RPMBUILD_DIR)/SPECS
RPMSRPMS_DIR    := $(RPMBUILD_DIR)/SRPMS
RPMMOCK_DIR     := $(RPMBUILD_DIR)/MOCK-RPMS


.PHONY: all
all: tests

.PHONY: halon
halon:
	stack build mero-halon \
		--extra-include-dirs=$(M0_SRC_DIR) \
		--ghc-options='$(GHC_OPTIONS)' \
		--no-test

.PHONY: tests
tests:
	stack build mero-halon \
		--extra-include-dirs=$(M0_SRC_DIR) \
		--ghc-options='$(GHC_OPTIONS)' \
		--test \
		--no-run-tests

.PHONY: setup
setup:
	stack setup

.PHONY: dist
dist:
	echo "module Version where \
	      gitDescribe = \"$(shell git describe --long --always || echo UNKNOWN)\"; \
	      gitCommitHash = \"$(shell git rev-parse HEAD || echo UNKNOWN)\"; \
	      gitCommitDate = \"$(shell git log -1 --format='%cd' || echo UNKNOWN)\";" \
	      > mero-halon/src/lib/Version.hs
	git archive --format=tar.gz --prefix=halon/ HEAD -o $(DIST_FILE)
	git checkout mero-halon/src/lib/Version.hs

.PHONY: __rpm_pre
__rpm_pre:
	$(MAKE) dist
	mkdir -p $(RPMSOURCES_DIR) \
	         $(RPMSPECS_DIR) \
	         $(RPMSRPMS_DIR) \
	         $(RPMMOCK_DIR)
	mv $(DIST_FILE) $(RPMSOURCES_DIR)
	chown $$(id -u):$$(id -g) $(RPMSOURCES_DIR)/$(DIST_FILE)
	cp halon.spec $(RPMSPECS_DIR)
	chown $$(id -u):$$(id -g) $(RPMSPECS_DIR)/halon.spec

.PHONY: __rpm
__rpm:
	rpmbuild -ba $(RPMSPECS_DIR)/halon.spec \
		 --define "_topdir $(RPMBUILD_TOPDIR)" \
		 --define "h_version ${VERSION}" \
		 --define "h_git_revision ${GITREV}" \
		 $(RPMBUILD_FLAGS)

.PHONY: __rpm_srpm
__rpm_srpm:
	rpmbuild -bs $(RPMSPECS_DIR)/halon.spec \
		 --define "_topdir $(RPMBUILD_TOPDIR)" \
		 --define "h_version ${VERSION}" \
		 --define "h_git_revision ${GITREV}" \
		 $(RPMBUILD_FLAGS)

.PHONY: __rpm_mock
__rpm_mock:
	mock -r $(MOCK_CONFIG) --buildsrpm \
		--spec $(RPMSPECS_DIR)/halon.spec \
		--sources $(RPMSOURCES_DIR) \
		--resultdir $(RPMMOCK_DIR) \
		--define "h_version ${VERSION}" \
		--define "h_git_revision ${GITREV}" \
		--no-clean --no-cleanup-after
	mock -r $(MOCK_CONFIG) --install \
		$(RPMBUILD_DIR)/RPMS/x86_64/mero-[[:digit:]]*.rpm \
		$(RPMBUILD_DIR)/RPMS/x86_64/mero-devel*.rpm \
		--resultdir $(RPMMOCK_DIR) \
		--no-clean --no-cleanup-after
	mock -r $(MOCK_CONFIG) --rebuild $(RPMMOCK_DIR)/halon*.src.rpm \
		--resultdir $(RPMMOCK_DIR) \
		--define "h_version ${VERSION}" \
		--define "h_git_revision ${GITREV}" \
		--enable-network \
		--no-clean

.PHONY: rpms
rpms:
	$(MAKE) __rpm_pre
	$(MAKE) __rpm

.PHONY: rpms-mock
rpms-mock:
	$(MAKE) __rpm_pre
	$(MAKE) __rpm_mock

.PHONY: srpm
srpm:
	$(MAKE) __rpm_pre
	$(MAKE) __rpm_srpm

.PHONY: help
help:
	@echo 'Setup targets:'
	@echo '  setup           - set up Haskell build environment'
	@echo ''
	@echo 'Build targets:'
	@echo '  tests           - build Halon and tests, this is default target'
	@echo '  halon           - build only Halon without tests'
	@echo ''
	@echo 'Distribution targets:'
	@echo '  dist            - recreate package.tar.gz from all source files'
	@echo '  srpm            - build Halon source rpm package'
	@echo '  rpms            - build Halon rpm and srpm packages'
	@echo '  rpms-mock       - build Halon rpm and srpm packages using'
	@echo '                    "mock" environment (ensures clean rpm deps)'

# This project uses The Stack build tool. Please refer to the README
# for build instructions.

GITREV          := git$(shell git rev-parse --short HEAD)
# assume the first part of `git describe` is a tag in format 'n.m'
VERSION         := $(or $(shell git describe | cut -f1 -d-), UNKNOWN)
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

#
# RPMs -------------------------------------------------------------------- {{{1
#

.PHONY: dist
dist:
	rm -f $(DIST_FILE)
	echo "module Version where \
	      gitDescribe :: String; \
	      gitDescribe = \"$(shell git describe --long --always || echo UNKNOWN)\"; \
	      gitCommitHash :: String; \
	      gitCommitHash = \"$(shell git rev-parse HEAD || echo UNKNOWN)\"; \
	      gitCommitDate :: String; \
	      gitCommitDate = \"$(shell git log -1 --format='%cd' || echo UNKNOWN)\";" \
	      > mero-halon/src/lib/Version.hs
	git archive --prefix=halon/ HEAD -o $(DIST_FILE:.gz=)
	tar -rf $(DIST_FILE:.gz=) --transform 's#^#halon/#' mero-halon/src/lib/Version.hs
	gzip $(DIST_FILE:.gz=)
	git checkout mero-halon/src/lib/Version.hs
	ln -sf ../$(DIST_FILE) docker/halon-dist.tar.gz

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

#
# Docker ------------------------------------------------------------------ {{{1
#

CENTOS_RELEASE  := 7
NAMESPACE       := registry.gitlab.mero.colo.seagate.com
DOCKER          := docker

INAME = $(@:%-image=%)
CNAME = $(@:%-container=%)

.PHONY: docker-images
docker-images: docker-image-latest \
               docker-image-7.5 \
               docker-image-7.6 \
               docker-image-sage \
               docker-image-sage-vm

.PHONY: docker-image-latest
docker-image-latest docker-image-7: halon-devel-image

.PHONY: docker-image-7.6
docker-image-7.6: CENTOS_RELEASE := 7.6
docker-image-7.6: halon-devel-image

.PHONY: docker-image-7.5
docker-image-7.5: CENTOS_RELEASE := 7.5
docker-image-7.5: halon-devel-image

.PHONY: docker-image-eos
docker-image-eos: CENTOS_RELEASE := eos
docker-image-eos: halon-devel-image

.PHONY: docker-image-sage
docker-image-sage: CENTOS_RELEASE := sage
docker-image-sage: halon-devel-image

.PHONY: docker-image-sage-vm
docker-image-sage-vm: CENTOS_RELEASE := sage-vm
docker-image-sage-vm: halon-devel-image


.PHONY: halon-devel-image
halon-devel-image: dist
	cd docker \
	&& tar -ch . \
	   | $(DOCKER) build \
			--build-arg CENTOS_RELEASE=$(CENTOS_RELEASE) \
			-t $(NAMESPACE)/$(INAME):$(CENTOS_RELEASE) \
			-t $(NAMESPACE)/mero/halon:$(CENTOS_RELEASE) \
			$(DOCKER_OPTS) -

name := halon*
tag  := *
docker-push:
	@for img in $$(docker images --filter=reference='$(NAMESPACE)/$(name):$(tag)' \
				    --format '{{.Repository}}:{{.Tag}}' | grep -v none) \
		    $$(docker images --filter=reference='$(NAMESPACE)/mero/$(name):$(tag)' \
				    --format '{{.Repository}}:{{.Tag}}' | grep -v none) ; \
	do \
		echo "---> $$img" ; \
		$(DOCKER) push $$img ; \
	done

docker-clean:
	@for img in $$(docker images --filter=reference='$(NAMESPACE)/$(name):$(tag)' \
				    --format '{{.Repository}}:{{.Tag}}') \
		    $$(docker images --filter=reference='$(NAMESPACE)/mero/$(name):$(tag)' \
				    --format '{{.Repository}}:{{.Tag}}') ; \
	do \
		echo "---> $$img" ; \
		$(DOCKER) rmi $$img ; \
	done

#
# Help -------------------------------------------------------------------- {{{1
#

.PHONY: help
help:
	@echo 'Setup targets:'
	@echo '  setup           - set up Haskell build environment'
	@echo ''
	@echo 'Build targets:'
	@echo '  tests           - build Halon and tests, this is default target'
	@echo '  halon           - build only Halon without tests'
	@echo '  clean           - clean local packages'
	@echo ''
	@echo 'Distribution targets:'
	@echo '  dist            - recreate package.tar.gz from all source files'
	@echo '  srpm            - build Halon source rpm package'
	@echo '  rpms            - build Halon rpm and srpm packages'
	@echo '  rpms-mock       - build Halon rpm and srpm packages using'
	@echo '                    "mock" environment (ensures clean rpm deps)'
	@echo ''
	@echo 'Infrastructure targets:'
	@echo '  docker-images   - create docker images for CI environment'
	@echo "  docker-push     - upload local $(NAMESPACE)/* images to docker hub repository"
	@echo "  docker-clean    - remove local $(NAMESPACE)/* images"


# vim: textwidth=80 nowrap foldmethod=marker

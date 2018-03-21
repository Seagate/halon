# This project uses The Stack build tool. Please refer to the README
# for build instructions.

BUILD_NUMBER = 000
VERSION = $(shell git describe --long --always | tr '-' '_')
MOCK_CONFIG = default
SRC_RPM_DIR := $(shell mktemp -du)
RPMBUILD_DIR = $(HOME)/rpmbuild

.PHONY: rpm
rpm:
	mkdir -p $(RPMBUILD_DIR)
	echo "module Version where \
	      gitDescribe = \"$(shell git describe --long --always || echo UNKNOWN)\"; \
	      gitCommitHash = \"$(shell git rev-parse HEAD || echo UNKNOWN)\"; \
	      gitCommitDate = \"$(shell git log -1 --format='%cd' || echo UNKNOWN)\";" \
          > mero-halon/src/lib/Version.hs
	git archive --format=tar --prefix=halon/ HEAD | gzip > $(RPMBUILD_DIR)/halon.tar.gz
	mock -r $(MOCK_CONFIG) --buildsrpm \
		--spec halon.spec --sources $(RPMBUILD_DIR) \
		--resultdir $(SRC_RPM_DIR) \
		--define "_gitversion ${VERSION}" \
		--define "_buildnumber ${BUILD_NUMBER}"
	mock -r $(MOCK_CONFIG) --rebuild $(SRC_RPM_DIR)/*.src.rpm \
		--resultdir $(RPMBUILD_DIR) \
    --define "_gitversion ${VERSION}" \
		--define "_buildnumber ${BUILD_NUMBER}"

ifeq ($(RPMBUILD_DIR),rpmbuild)
    RPMBUILD_TOPDIR := $(CURDIR)/$(RPMBUILD_DIR)
else
    RPMBUILD_TOPDIR := $(RPMBUILD_DIR)
endif

# This target will generate a distributable RPM based on the current checkout.
# By default, it will generate a binary RPM in ./rpmbuild/RPMS/x86_64 and
# a pseudo-source tar in ./rpmbuild/SRPMS. It's possible to override the default
# output location by specifying a new value of RPMBUILD_DIR variable in the
# command-line, e.g. `make rpm-dev RPMBUILD_DIR=~/rpmbuild`.
rpm-dev:
	mkdir -p $(RPMBUILD_DIR)
	mkdir -p $(RPMBUILD_DIR)/SOURCES/role_maps
	mkdir -p $(RPMBUILD_DIR)/SOURCES/systemd
	mkdir -p $(RPMBUILD_DIR)/SOURCES/tmpfiles.d
	mkdir -p $(RPMBUILD_DIR)/SPECS
	cp .stack-work/install/x86_64-linux/lts-8.3/8.0.2/bin/halond $(RPMBUILD_DIR)/SOURCES/
	cp .stack-work/install/x86_64-linux/lts-8.3/8.0.2/bin/halonctl $(RPMBUILD_DIR)/SOURCES/
	cp .stack-work/install/x86_64-linux/lts-8.3/8.0.2/bin/halon-cleanup $(RPMBUILD_DIR)/SOURCES/
	cp systemd/halond.service $(RPMBUILD_DIR)/SOURCES/
	cp systemd/halon-satellite.service $(RPMBUILD_DIR)/SOURCES/
	cp systemd/halon-cleanup.service $(RPMBUILD_DIR)/SOURCES/
	cp systemd/sysconfig/halond.example $(RPMBUILD_DIR)/SOURCES/
	cp mero-halon/scripts/localcluster $(RPMBUILD_DIR)/SOURCES/halon-simplelocalcluster
	cp mero-halon/scripts/hctl $(RPMBUILD_DIR)/SOURCES/hctl
	cp mero-halon/scripts/setup-rabbitmq-perms.sh $(RPMBUILD_DIR)/SOURCES/setup-rabbitmq-perms.sh
	cp mero-halon/scripts/mero_clovis_role_mappings.ede $(RPMBUILD_DIR)/SOURCES/role_maps/clovis.ede
	cp mero-halon/scripts/mero_provisioner_role_mappings.ede $(RPMBUILD_DIR)/SOURCES/role_maps/prov.ede
	cp mero-halon/scripts/mero_s3server_role_mappings.ede $(RPMBUILD_DIR)/SOURCES/role_maps/s3server.ede
	cp mero-halon/scripts/halon_roles.yaml $(RPMBUILD_DIR)/SOURCES/role_maps/halon_role_mappings
	cp mero-halon/scripts/tmpfiles.d/halond.conf $(RPMBUILD_DIR)/SOURCES/tmpfiles.d/halond.conf
	cp halon-dev.spec $(RPMBUILD_DIR)/SPECS/
	chown -R $$(id -u):$$(id -g) $(RPMBUILD_DIR)/
	rpmbuild --define "_topdir $(RPMBUILD_TOPDIR)" \
		 --define "_gitversion ${VERSION}" \
		 -ba $(RPMBUILD_DIR)/SPECS/halon-dev.spec

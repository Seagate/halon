# This project uses The Stack build tool. Please refer to the README
# for build instructions.

BUILD_NUMBER = 000
VERSION = $(shell git describe --long --always | tr '-' '_')
MOCK_CONFIG = default
SRC_RPM_DIR := $(shell mktemp -du)
RESULT_DIR = rpmbuild

.PHONY: rpm
rpm:
	mkdir -p $(RESULT_DIR)
	echo "module Version where \
	      gitDescribe = \"$(shell git describe --long --always || echo UNKNOWN)\"; \
	      gitCommitHash = \"$(shell git rev-parse HEAD || echo UNKNOWN)\"; \
	      gitCommitDate = \"$(shell git log -1 --format='%cd' || echo UNKNOWN)\";" \
          > mero-halon/src/lib/Version.hs
	git archive --format=tar --prefix=halon/ HEAD | gzip > $(RESULT_DIR)/halon.tar.gz
	mock -r $(MOCK_CONFIG) --buildsrpm \
		--spec halon.spec --sources $(RESULT_DIR) \
		--resultdir $(SRC_RPM_DIR) \
		--define "_gitversion ${VERSION}" \
		--define "_buildnumber ${BUILD_NUMBER}"
	mock -r $(MOCK_CONFIG) --rebuild $(SRC_RPM_DIR)/*.src.rpm \
		--resultdir $(RESULT_DIR) \
    --define "_gitversion ${VERSION}" \
		--define "_buildnumber ${BUILD_NUMBER}"

# This target will generate a distributable RPM based on the current
# checkout. It will generate a binary RPM in ./rpmbuild/RPMS/x86_64
# and a pseudo-source tar in ./rpmbuild/SRPMS
rpm-dev:
	mkdir -p rpmbuild/SOURCES/role_maps
	cp .stack-work/install/x86_64-linux/lts-5.17/7.10.3/bin/halond rpmbuild/SOURCES/
	cp .stack-work/install/x86_64-linux/lts-5.17/7.10.3/bin/halonctl rpmbuild/SOURCES/
	cp .stack-work/install/x86_64-linux/lts-5.17/7.10.3/bin/genders2yaml rpmbuild/SOURCES/
	cp systemd/halond.service rpmbuild/SOURCES/
	cp systemd/halon-satellite.service rpmbuild/SOURCES/
	cp mero-halon/scripts/localcluster rpmbuild/SOURCES/halon-simplelocalcluster
	cp mero-halon/scripts/hctl rpmbuild/SOURCES/hctl
	cp mero-halon/scripts/mero_role_mappings.ede rpmbuild/SOURCES/role_maps/genders.ede
	cp mero-halon/scripts/mero_provisioner_role_mappings.ede rpmbuild/SOURCES/role_maps/prov.ede
	cp mero-halon/scripts/halon_roles.yaml rpmbuild/SOURCES/role_maps/halon_role_mappings
	rpmbuild --define "_topdir ${PWD}/rpmbuild" --define "_gitversion ${VERSION}" -ba halon-dev.spec

VERSION = $(shell git describe --long --always | tr '-' '_' | cut -c 2-)

# This target will generate a distributable RPM based on the current
# checkout. It will generate a binary RPM in ./rpmbuild/RPMS/x86_64
# and a pseudo-source tar in ./rpmbuild/SRPMS
rpm:
	mkdir -p rpmbuild/SOURCES/role_maps
	cp .stack-work/install/x86_64-linux/lts-3.11/7.10.2/bin/halond rpmbuild/SOURCES/
	cp .stack-work/install/x86_64-linux/lts-3.11/7.10.2/bin/halonctl rpmbuild/SOURCES/
	cp .stack-work/install/x86_64-linux/lts-3.11/7.10.2/bin/genders2yaml rpmbuild/SOURCES/
	cp systemd/halond.service rpmbuild/SOURCES/
	cp systemd/halon-satellite.service rpmbuild/SOURCES/
	cp mero-halon/scripts/localcluster rpmbuild/SOURCES/halon-simplelocalcluster
	cp mero-halon/scripts/mero_role_mappings.ede rpmbuild/SOURCES/role_maps/genders.ede
	cp mero-halon/scripts/mero_provisioner_role_mappings.ede rpmbuild/SOURCES/role_maps/prov.ede
	rpmbuild --define "_topdir ${PWD}/rpmbuild" --define "_gitversion ${VERSION}" -ba rpmbuild/SPECS/halon-make.spec

.PHONY: coverage
coverage:
	rm -rf coverage
	bash run-coverage.sh

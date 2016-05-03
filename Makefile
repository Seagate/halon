# This project uses The Stack build tool. Please refer to the README
# for build instructions.

MOCK_CONFIG = default
SRC_RPM_DIR := $(shell mktemp -du)
RESULT_DIR = $(pwd)/rpmbuild

.PHONY: rpm
rpm:
	mkdir -p $(RESULT_DIR)
	git archive --format=tar --prefix=halon/ HEAD | gzip > $(RESULT_DIR)/halon.tar.gz
	mock -r $(MOCK_CONFIG) --buildsrpm \
		--spec halon.spec --sources $(RESULT_DIR) \
		--resultdir $(SRC_RPM_DIR)
	mock -r $(MOCK_CONFIG) --rebuild $(SRC_RPM_DIR)/*.src.rpm --resultdir $(RESULT_DIR)

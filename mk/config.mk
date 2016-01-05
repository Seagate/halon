ROOT_DIR = $(shell pwd)

# LANG to be used in building cabal packages during RPM build.
HA_BUILD_LANG = C.UTF-8

# The `ci' target uses this genders file.
export GENDERS = $(shell pwd)/mero-halon/scripts/genders-parsci

RPMROOT = $(shell pwd)/rpmbuild

# The git branch of this repository whose HEAD will
# serve as the basis of RPM packaging.
RPMBRANCH = master

# DB file directory for Mero used by network-transport-rpc
# CAUTION: This path will be removed by superuser.
export NTR_DB_DIR = $(shell pwd)/testdb

GHC_VERSION = $(shell ghc --numeric-version)

PACKAGE_DIR = $(ROOT_DIR)/
VENDOR_DIR = $(ROOT_DIR)/vendor/

PACKAGES := distributed-commands \
           distributed-process-trans \
           distributed-process-scheduler \
           distributed-process-test \
           network-transport-controlled \
           consensus \
           consensus-paxos \
           replicated-log \
           sspl \
           halon \
           mero-halon

ifdef USE_RPCLITE
PACKAGES += rpclite
endif

ifdef USE_MERO
PACKAGES += confc
endif

ifdef USE_RPC
PACKAGES += network-transport-rpc
endif

VENDOR_PACKAGES = distributed-process \
                  tasty-files \
                  options-schema \
                  netwire \
                  network-transport-tcp \
                  network-transport-inmemory

CEP_DIR = $(ROOT_DIR)/cep/

CEP_PACKAGES := cep

export HALON_TRACING = consensus-paxos replicated-log EQ EQ.producer MM RS RG

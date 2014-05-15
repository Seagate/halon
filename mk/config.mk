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

# By default, don't reuse any packages in the user or global database
# to satisfy dependencies. But for faster builds, you can
# try --package-db=user or package-db=user.
CABAL_FLAGS = --package-db=clean

GHC_VERSION = $(shell ghc --numeric-version)

SANDBOX_DEFAULT = $(shell pwd)/.cabal-sandbox-default
SANDBOX_DEFAULT_CONFIG = $(shell pwd)/cabal.sandbox-default.config
CABAL_DEFAULT_SANDBOX  = --sandbox-config-file=$(SANDBOX_DEFAULT_CONFIG)

# When building with the scheduler enabled, use a different sandbox.
SANDBOX_SCHED = $(shell pwd)/.cabal-sandbox-scheduler
SANDBOX_SCHED_CONFIG = $(shell pwd)/cabal.sandbox-scheduler.config
CABAL_SCHED_SANDBOX  = --sandbox-config-file=$(SANDBOX_SCHED_CONFIG)

PACKAGES = $(ROOT_DIR)/distributed-process-scheduler/ \
           $(ROOT_DIR)/distributed-process-test/ \
           $(ROOT_DIR)/distributed-process-trans/ \
           $(ROOT_DIR)/consensus/ \
           $(ROOT_DIR)/consensus-paxos/ \
           $(ROOT_DIR)/replicated-log/ \
           $(ROOT_DIR)/network-transport-rpc/ \
           $(ROOT_DIR)/confc/ \
           $(ROOT_DIR)/halon/ \
           $(ROOT_DIR)/mero-halon/

VENDOR_PACKAGES = $(ROOT_DIR)/vendor/distributed-process \
                  $(ROOT_DIR)/vendor/tasty-files \
                  $(ROOT_DIR)/vendor/acid-state

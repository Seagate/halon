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

PACKAGE_DIR = $(ROOT_DIR)/
VENDOR_DIR = $(ROOT_DIR)/vendor/

PACKAGES := distributed-process-scheduler \
           distributed-process-test \
           distributed-process-trans \
           consensus \
           consensus-paxos \
           replicated-log \
           halon \
           mero-halon

ifdef USE_RPC
PACKAGES += network-transport-rpc \
           confc
endif

VENDOR_PACKAGES = distributed-process \
                  tasty-files \
		  acid-state

# Packages that doesn't work with deterministic scheduler
NON_SCHED := halon \
             mero-halon

ROOT_DIR = $(shell pwd)

# LANG to be used in building cabal packages during RPM build.
HA_BUILD_LANG = C.UTF-8

# The `ci' target uses this genders file.
export GENDERS = $(shell pwd)/mero-ha/scripts/genders-parsci

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

SANDBOX_DEFAULT = $(shell pwd)/.cabal-sandbox
SANDBOX_DEFAULT_DB = $(shell pwd)/.cabal-sandbox/x86_64-linux-ghc-$(GHC_VERSION)-packages.conf.d

# When building with the scheduler enabled, use a different sandbox.
SANDBOX_SCHED = $(shell pwd)/.cabal-sandbox-scheduler
SANDBOX_SCHED_DB = $(SANDBOX_SCHED)/x86_64-linux-ghc-$(GHC_VERSION)-packages.conf.d
# Halon

Halon is a fault tolerant, resilient system for maintaining a globally
consistent view of large clusters and automatically repairing them in
real-time as faults arise.

# Building from sources

Prerequisites:

```shell
sudo yum install leveldb-devel libgenders-devel

# Install the Haskell Tool Stack
curl -sSL https://get.haskellstack.org/ | sh

# Get GHC
scripts/h0 setup
```

Build Mero first

```shell
(cd /path/to/mero && scripts/m0 make)
```

then build Halon

```shell
M0_SRC_DIR=/path/to/mero scripts/h0 rebuild
```

# Building and installing rpm packages

```shell
( cd /path/to/mero &&
  make rpms-notests &&
  sudo yum install ~/rpmbuild/RPMS/x86_64/mero*.rpm )
make rpms
sudo yum install ~/rpmbuild/RPMS/x86_64/halon*.rpm
```

# Documentation

The full documentation for Halon is kept in the `doc/` directory. To
build the documentation and view it in your browser:

```shell
cd doc
stack exec make html
```

You can also generate PDF's for each document in the set, as well as
the man pages for user commands:

```shell
stack exec make latexpdf
stack exec make man
```

# Unit tests

```shell
scripts/h0 test
```

# Starting/stopping the cluster

Single-node cluster:

```shell
scripts/h0 start
scripts/h0 stop
```

There is also an example script in `mero-halon/scripts/simplecluster.sh`
which runs a small two node cluster on the localhost. This script
relies on `HALON_ROOT` being set to a directory containing the
`halond` and `halonctl` binaries.

By default, `halonctl` attempts to listen on the local hostname. This
will fail if there is not an entry for the FQDN in `/etc/hosts`. In
this case, you can either add such an entry or use the `-l` option to
specify an alternate listen address.

Also by default, Halon attempts to verify that it is running against the
same version of the Mero library that it was built with. This check can
prevent unexpected bugs, but may occasionally inhibit testing. You can disable
this check by setting the `DISABLE_MERO_COMPAT_CHECK` environment variable.

# System requirements

Architecture: amd64, x86.

OS requrements: geneneric linux distribution
  In case of mero build: Linux distribution should be supported by mero.
  System libraries: leveldb, libgmp, libffi, rabbitmq-c.

Memory requirements:
   0.5Gb - singlenode setup.
   2Gb   - 6 nodes cluster.


# Halon

Halon is a fault tolerant, resilient system for maintaining a globally
consistent view of large clusters and automatically repairing them in
real-time as faults arise.

# NOTE

Please note that this code was originally developed for the CORTX project but it has been deprecated and is no longer currently used. However, we are having to make it publicly available for historical interest as well as any other reasons that someone might be interested. All interested parties are encouraged to try to use this software for whatever purpose that might be of benefit to them.

# Building from sources

Prerequisites:

```shell
sudo yum install leveldb-devel libgenders-devel

# Install the Haskell Tool Stack
curl -sSL https://get.haskellstack.org/ | sh
```

Build Mero first

```shell
(cd /path/to/mero && scripts/m0 make)
```

then build Halon

```shell
M0_SRC_DIR=/path/to/mero scripts/h0 make
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

# Running tests

Unit tests:

```shell
scripts/h0 test
```

System tests:

```shell
scripts/h0 run-st
```

# Starting/stopping the cluster

Single-node cluster:

```shell
# Install Mero and Halon systemd services; start halond-s;
# generate facts file.
scripts/h0 init

# Bootstrap the cluster.
hctl mero bootstrap

# Wait for all cluster processes to come online.
hctl mero status
sleep 90  # Zzz...
hctl mero status

# Stop the cluster.
hctl mero stop

# Stop halond-s; erase cluster data, metadata and generated configuration;
# uninstall systemd services.
scripts/h0 fini
```

Multi-node cluster:

```shell
# Prepare cluster configuration file.
cat >/data/cluster.yaml <<EOF
confds: [ cmu.local ]
ssus:
  - host:  ssu1.local
    disks: /dev/sd[b-g]
  - host:  ssu2.local
    disks: /dev/sd[b-g]
clovis-apps: [ client1.local ]
EOF

# Install Mero and Halon systemd services; start halond-s;
# generate facts file.
M0_CLUSTER=/data/cluster.yaml scripts/h0 init

# Bootstrap the cluster.
hctl mero bootstrap

# Wait for all cluster processes to come online.
hctl mero status
sleep 90  # Zzz...
hctl mero status

# Stop the cluster.
hctl mero stop

# Stop halond-s; erase cluster data, metadata and generated configuration;
# uninstall systemd services.
M0_CLUSTER=/data/cluster.yaml scripts/h0 fini
```

# Caveats

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

# Halon

Halon is a fault tolerant, resilient system for maintaining a globally
consistent view of large clusters and automatically repairing them in
real-time as faults arise.

# Checking out this repository

This repository includes a number of submodules. To check everything
out at once, use

```
$ git clone --recursive git@github.com:tweag/halon
```

**Note:** You may need to patch up the default URL's for Mero
submodules, if you do not have access to their upstream location:

```
$ git clone git@github.com:tweag/halon
$ git submodule sync
$ git submodule update --init
$ cd vendor/mero
$ git submodule init
$ git config submodule.extra-libs/galois.url git@github.com:tweag/mero-galois
$ git config submodule.extra-libs/gf-complete.url git@github.com:tweag/mero-gf-complete
$ git config submodule.extra-libs/yaml.url git@github.com:tweag/mero-yaml
$ git submodule update
```

You can still build Halon even if you don't checkout any of the Mero
submodules, but without Mero support.

# How to build

Prerequesites:
* [Docker][docker] >= 1.8
* [Haskell Stack][haskell-stack] >= 0.1.8

The build will happen inside an ephemeral Docker container within
which the project root directory is mounted as a volume. As such,
there are no particular installation requirements on the host beyond
being able to launch Docker and to invoke Stack commands.

Login to [quay.io][quay] to pull the private base Docker image, using
the credentials provided to you:

```
$ docker login quay.io
```

This step is required only once. To initialize the project (from the
project's root directory):

```
# Implicitly mount Mero source as a volume inside container.
$ alias stack="stack --docker-mount `pwd`/vendor/mero:/mero"
$ stack docker pull
$ stack setup                           # Download compiler toolchain.
```

You need to build Mero first. If your host's kernel version matches
that expected by mero, you can configure and build in a single
command:

```
$ stack exec ./vendor/mero/scripts/m0 rebuild
```

Otherwise try the following:

```
$ cd vendor/mero
$ stack exec -- ./autogen.sh
$ stack exec -- ./configure --with-linux="/usr/src/kernels/*"
$ stack exec -- make
```

Building Halon is then simply:

```
$ stack build
```

See the [Stack documentation][stack-doc] for further information on
how to run tests, benchmarks, or build the API documentation. You can
do all of that at once with

```
$ stack build --test --haddock --bench
```

**Note:** Mero support, together with tests when Mero support is
enabled, requires Mero kernel modules to be loadable in the host
kernel. See [tweag/seagate-boxes][seagate-boxes] to construct a VM
with a kernel suitable for this.

[docker]: https://www.docker.com/
[haskell-stack]: https://github.com/commercialhaskell/stack
[quay]: https://quay.io
[seagate-boxes]: https://github.com/tweag/seagate-boxes
[stack-doc]: http://docs.haskellstack.org/en/stable/README.html

# Running

There is an example script in `mero-halon/scripts/simplecluster.sh`
which runs a small two node cluster on the localhost. This script
relies on `HALON_ROOT` being set to a directory containing the
`halond` and `halonctl` binaries.

By default, `halonctl` attempts to listen on the local hostname. This
will fail if there is not an entry for the FQDN in `/etc/hosts`. In
this case, you can either add such an entry or use the `-l` option to
specify an alternate listen address.

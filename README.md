# Build requirements

Prequisites:
 * ghc-7.8.3 -- http://www.haskell.org/ghc
 * cabal-install >= 1.20 -- http://www.haskell.org/cabal/download.html
 * mero (optional, only needed for mero-halon and MERO_RPC)

Environment variables if using mero:
 * MERO_ROOT: Must point to the root of the mero source and build tree
 * GENDERS: Must point to a genders file describing the current host
   and perhaps others. See mero-halon/scripts/genders-parsci for an
   example. The file can also be generated by running:

   ```
   $ mero-halon/scripts/mkgenders > genders-`hostname -s`
   ```

# Initial setup in a repository clone

To initialize our repository, we clone the submodules and install all
the dependencies into a cabal sandbox with the following commands:

```
$ git submodule update --init --recursive
$ make dep
```

# Building and testing packages

Note that when building with mero support, the testing process requires root
privileges (via sudo), since mero loads custom kernel modules.

Building, testing and installing all the sub-packages to the sandbox:
```
$ cd <git-clone-rootdir>
$ make
```

You can re-run `make` again after changing the source code of any
package, and the affected packages will be rebuilt and retested, then
reinstalled to the sandbox. Always do this while staying at the
top-level directory. The `Makefile`s in the sub-directories are
outdated and are soon to be removed.

Don't be alerted by the error message "everything is already
installed, use --reinstall", that just means that you didn't change
any source code, if you actually did change something, the rebuild
process will find it.

Cleaning can be done with `make clean` as usual, and therefore a fresh
rebuild and retest can be done with `make clean build`.

Building just one package can be done with:
```
$ make PACKAGES=replicated-log
```

Testing can be disabled:
```
$ make NO_TESTS=1
```

This last two feature is not very safe to use, but "works most of the
time", see next section for details.

Building the rpm package:
```
$ make rpm
```

# Understanding the build process (and its shortcomings)

The Halon implementation is composed of several packages. Each package
is provided in a separate folder (`distributed-process-scheduler`,
`replicated-log`, etc.). Also, in the `vendor/` subdirectory there are
a few git submodules that are conceptually just "private hackage" packages.

The top-level directory contains a Makefile that knows about all these
sub-packages, but knows nothing about their dependency relations (as
that will be handled by Cabal automagically).

The build process does the following:
  - `make dep` phase:
    - initializes an empty cabal sandbox,
    - calls `cabal sandbox add-source` for sub-packages and git submodules,
    - installs all the dependencies of the packages and submodules from hackage,
  - `make build` phase:
    - calls `cabal install` for all the sub-packages.

The dependency tracking is done by the last `cabal install`
command. The `sandbox add-source` makes it so that if the source
changes in a sub-package, then that package (and the packages that
depend on it) will be rebuilt, retested and reinstalled.

Caveats:
  - Cabal insists on the sandbox being consistent at all times, and monitors the
    sources of **all** sandbox installed packages. This means that downstream
    dependencies may be rebuilt, even if none of the packages provided
    in `PACKAGES` depend on them. For example, if `halon` is installed in the
    sandbox and you modify some source file in that package,
    ```
    make PACKAGES=replicated-log
    ```
    will reinstall `halon` regardless.

  - Testing will only be done for the packages that are mentioned in the
    `PACKAGES` make argument (by default, for all of the packages if you don't
    use the `PACKAGES` argument).

  - The effects of the NO_TESTS flag are not entirely local to a given make run
    (it has "memory" in a sense). Ordinarily, `make build` does testing before
    installing packages, but when you do a `make NO_TESTS=1 build`, the packages
    are installed without testing, and further `make build` commands will only
    build, and thus will only run tests for the newly changed parts of the
    repository.

  - Rule of thumb: if you ever change your command line regarding the
    `PACKAGES` or `NO_TESTS` attribute, do a `make clean` before
    continuing with your builds, and **always** do a `make clean
    build` without any further make arguments to conclude whether your
    change passes all of the test suite.

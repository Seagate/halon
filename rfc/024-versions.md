# RFC: Versioning

## Introduction

Halon needs a sensible scheme for handling versioning, particularly in light
of upgrade requirements. This RFC documents a suggested scheme to use.

## Requirements

- We should be able to distinguish between a version requiring explicit
  update (through migrations, TS coup) from one which seamlessly interoperates
  with previous versions.

- Given two git commits on a single branch, the later commit should have a
  greater version number than the earlier commit.

- Given two different builds (owing perhaps to upstream changes) of the same
  commit, the later build should have a greater version number than the earlier
  build.

- Version information from development builds (e.g. `make rpm-dev`) should for
  the large part be equal to version information from production builds of that
  same commit.

- Version information embedded in the application (`halond -v`) should for the
  large part be equal to version information present in the packaged version of
  that application.

- It should be possible to easily determine the git commit from the built or
  packaged application.

- It should be possible to build production builds without git metadata. For
  such builds, git related components of the version may not be available.

## Version semantics

We propose a variant on semantic versioning:

``` release.major.minor.build-gitrev ```

- `release` should largely track major releases of the castor project. For
  example, this should be bumped for teacake, chelseabun etc.
- `major` versions should indicate the necessity to run upgrade - this
  indicates that persisted state or wire format has changed.
- `minor` versions should be incremented automatically on any  change.
- `build` versions should be incremented on multiple builds of the same
  commit.
- `gitrev` provides the git revision of the source repository.

### Non-git builds

Where git metadata is not present, we would instead see a version:

``` release.major-nogit ```

For purposes of updates, only release and major versions should be considered.
As such, if a new version requires explicit updates, this MUST be accompanied
by a bump in the major version, along with a corresponding migration script.

Since release versions correspond to the wider Castor release cycle rather than
to halon internals, when we bump the release version, there may be no changes
which need update. In this case, we might create an "empty" migration to move
from the latest major version in release `n` to release `n+1`.

## Constructing version information

### Release and Major versions

Release and major versions should be controlled by the `Version` field of the
`mero-cabal` library.

For use in `halond` and `halonctl`, as well as to govern updates,
they can be extracted through use of the following:

```
import Paths_mero_halon (version)
```

We must also include this information into the RPM spec file. The easiest way
to extract this is likely to parse it directly from the `mero-halon.cabal` file.

### Minor version

We have two alternatives in defining the minor version; we can get the number
of commits since the last tag, or the total number of commits since the first
commit on the repository.

The former can be evaluated using the following:

```
git rev-list --count $(git describe --abbrev=0)..
```

The latter can be evaluated using the following:

```
git rev-list --count HEAD
```

The former has the slight advantage that numbers should be smaller, and we can
reset them to 0 on a bump to a major or release version. However, they run the
risk that an additional tag introduced without bumping the major or release
version might result in reset of the counter. As such, the latter seems the
safer counter.

### Build number

The build number is created and provided by the RE build infrastructure.
Development builds (those created using `make rpm-dev`) should instead include
the version "devel" in this field.

## Populating git version information

As currently, git information should be populated in-tree through use of the
`GitRev` module, and overwritten in the case of production builds by the
`make` or `nix` infrastructure before creating the git archive. An alternative
would be to use the `export-subst` capability of `git-archive`, but this [does
not support](https://git-scm.com/docs/git-log#_pretty_formats) all of the data
we need to export.

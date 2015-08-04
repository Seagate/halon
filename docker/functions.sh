GHCVERSION=7.10.2
CABALVERSION=1.22.4.0

function build-if-needed {

BASE=$1
HASH=$2
DOCKERDIR=$3

TAG=${BASE}:${HASH}

BRANCH=$(git symbolic-ref --short HEAD | sed 's/[^0-9a-zA-Z_\-]/_/g')
LATESTTAG=${BASE}:$BRANCH

docker --host=localhost:5555 pull $TAG

docker --host=localhost:5555 history $TAG

if [ "$?" == "0" ] ; then
  echo pulled OK - do not need to rebuild
  docker --host=localhost:5555 tag -f ${TAG} ${LATESTTAG}
  docker --host=localhost:5555 push $LATESTTAG || exit 1
  exit 0
fi

export COMMIT=$(git rev-parse HEAD)
echo COMMIT = $COMMIT

cat docker/${DOCKERDIR}/Dockerfile.in \
  | sed "s/@@COMMIT@@/${COMMIT}/g" \
  | sed "s/@@GHCVERSION@@/${GHCVERSION}/g" \
  | sed "s/@@CABALVERSION@@/${CABALVERSION}/g" \
  | sed "s/@@BASEVERSION@@/${BASEVERSION}/g" \
  > docker/${DOCKERDIR}/Dockerfile
docker --host=localhost:5555 build -t ${TAG} docker/${DOCKERDIR}/ || exit 1
docker --host=localhost:5555 tag -f ${TAG} ${LATESTTAG}
docker --host=localhost:5555 push $TAG || exit 1
docker --host=localhost:5555 push $LATESTTAG || exit 1

echo Docker tags pushed:
echo Docker image ${BASE}
echo Hashed tag is ${TAG}
echo Symbolic tag is ${LATESTTAG}

}

function generate-base-version {
GITVERSION=$(git rev-parse HEAD:docker/1-haskell-env-on-centos-7/)
VERSION=$(echo $GITVERSION $GHCVERSION $CABALVERSION | md5sum | cut --byte=1-32)
echo $VERSION
}


function generate-dep-version {
# this can be changed to cause a rebuild
# of the "make dep" image even when the
# automated detection below does not see
# a change.
MANUALVERSION=2015011602

# these are all hashed up to decide if this layer needs
# rebuilding or not.
# anything that can affect the dependencies should
# be hashed into this.

BASEVERSION=$(git rev-parse HEAD:docker/1-haskell-env-on-centos-7/)
CABALHASH=$(md5sum $(find . -name \*cabal) | md5sum)
VENDORHASH=$(git rev-parse HEAD:vendor/)
CABALCONFIGHASH=$(git rev-parse HEAD:cabal.config)
DOCKERDIRHASH=$(git rev-parse HEAD:docker/2-halon-deps/)
MAKEFILEHASH=$(git rev-parse HEAD:Makefile)

VERSION=$( (echo $BASEVERSION $MANUALVERSION $CABALVERSION $GHCVERSION $CABALHASH $VENDORHASH $CABALCONFIGHASH $DOCKERDIRHASH MAKEFILEHASH) | md5sum | cut --byte=1-32)

echo MANUALVERSION = $MANUALVERSION >&2
echo BASEVERSION = $BASEVERSION >&2
echo VERSION = $VERSION >&2

echo $VERSION
}

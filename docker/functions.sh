GHCVERSION=7.8.3
CABALVERSION=1.20.0.0

function build-if-needed {

TAG=$1
DOCKERDIR=$2

docker pull $TAG

docker history $TAG

if [ "$?" == "0" ] ; then
  echo pulled OK - do not need to rebuild
  exit 0
fi

export COMMIT=$(git rev-parse HEAD)
echo COMMIT = $COMMIT

cat docker/${DOCKERDIR}/Dockerfile.template \
  | sed "s/XXXCOMMITXXX/${COMMIT}/g" \
  | sed "s/XXXGHCVERSIONXXX/${GHCVERSION}/g" \
  | sed "s/XXXCABALVERSIONXXX/${CABALVERSION}/g" \
  | sed "s/XXXBASEVERSIONXXX/${BASEVERSION}/g" \
  > docker/${DOCKERDIR}/Dockerfile
docker build -t ${TAG} docker/${DOCKERDIR}/ || exit 1
docker push $TAG || exit 1

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
MANUALVERSION=2015010702

# these are all hashed up to decide if this layer needs
# rebuilding or not.
# anything that can affect the dependencies should
# be hashed into this.

BASEVERSION=$(git rev-parse HEAD:docker/1-haskell-env-on-centos-7/)
CABALHASH=$(md5sum $(find . -name \*cabal) | md5sum)
VENDORHASH=$(git rev-parse HEAD:vendor/)
CABALCONFIGHASH=$(git rev-parse HEAD:cabal.config)
DOCKERDIRHASH=$(git rev-parse HEAD:docker/2-halon-deps/)

VERSION=$( (echo $BASEVERSION $MANUALVERSION $CABALHASH $VENDORHASH $CABALCONFIGHASH $DOCKERDIRHASH) | md5sum | cut --byte=1-32)

echo MANUALVERSION = $MANUALVERSION >&2
echo BASEVERSION = $BASEVERSION >&2
echo VERSION = $VERSION >&2

echo $VERSION
}

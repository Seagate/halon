#!/bin/bash -e

WORKDIR=${WORKDIR:=~/h/cabal-installers}

# first, get a more recent version of cabal
# than the distro provides, including a
# bodge to work around unusual behaviour
# in the seagate network.
# This needs to happen before cabal-rpm is
# built so that it has a recent cabal
# library in it. (I think?)

# use the same sandbox for both so cabal-rpm has
# access to the cabal dev libraries.
mkdir -p $WORKDIR
cd $WORKDIR
git clone git@github.com:tweag/cabal.git
#ADD cabal-seagate-fix.tar.gz /h/cabal-installers/
cd ${WORKDIR}/cabal

# this will put the bodged Cabal package somewhere
# that cabal-install bootstrap will find it,
# rather than trying to download an unbodged version
# from the network.
mv Cabal Cabal-1.22.3.999
tar czvf Cabal-1.22.3.999.tar.gz Cabal-1.22.3.999/
mv Cabal-1.22.3.999.tar.gz cabal-install/

cd ${WORKDIR}/cabal/cabal-install

# EXTRA_CONFIGURE_OPTS here overrides the default
# configure opts of --enable-shared and --enable-library-profiling
# because the present (2015-05-13) ghc-7.10.1 RPM
# set does not contain profiling libraries.
# Possibly they will later, in which case
# profiling libraries can be re-enabled if profiling
# is desirable for this cabal.
EXTRA_CONFIGURE_OPTS="--enable-shared" PREFIX=${WORKDIR}/cabal-build ./bootstrap.sh

#cp -v /h/cabal-installers/cabal-build/bin/cabal /usr/local/bin/
export OPATH=$PATH
export PATH=${WORKDIR}/cabal-build/bin:$OPATH

# Now we have cabal bootstrapped...
# install it again, but so that the packages get
# registered properly, for use in the cblrpm build,
# in the installer sandbox.

cabal update

cd ${WORKDIR}
cabal sandbox init --sandbox=${WORKDIR}
cabal install cabal/Cabal-1.22.3.999/ cabal/cabal-install/
# cp -v /h/cabal-installers/bin/cabal /usr/local/bin/

cd ${WORKDIR}
git clone git@github.com:tweag/cabal-rpm.git
cd ${WORKDIR}/cabal-rpm

cabal sandbox init --sandbox=${WORKDIR}
cabal install
# cp /h/cabal-installers/bin/cblrpm /usr/local/bin/
# new path, losing the cabal-build bootstrap version of cabal
# export PATH=/h/cabal-installers/bin:$OPATH


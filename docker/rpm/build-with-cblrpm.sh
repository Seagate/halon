#!/bin/bash -e

export WORKDIR=${WORKDIR:=~/h}
export HALONSRC=${HALONSRC:=~/halon}
export CBLRPM=${WORKDIR}/cabal-installers/bin/cblrpm
export PATH=${WORKDIR}/cabal-installers/bin/:$PATH

export CBLRPM_FREEZE=${HALONSRC}/cabal.config
export CBLRPM_PREFIX=halon

# network git repo does not have a configure
# script; if it was downloaded from hackage,
# it would. this makes it have one.
#pushd ${HALONSRC}/vendor/network
##autoreconf -i
#popd

export PATH=$PATH:${WORKDIR}/cabal-installers/cabal-build/bin

mkdir -p ~/rpmbuild/SOURCES
${CBLRPM} srpms ${WORKDIR}/cabal-installers/cabal/Cabal-1.22.3.999 || exit 14
${CBLRPM} srpms ${HALONSRC}/vendor/rank1dynamic || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/options-schema || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/tasty-files || exit 6
# ${CBLRPM} srpms ${HALONSRC}/vendor/network || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/network-transport || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/network-transport-tcp || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/distributed-static || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/distributed-process || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/distributed-process-extras || exit 6
${CBLRPM} srpms ${HALONSRC}/vendor/distributed-process-async || exit 6
${CBLRPM} srpms ${HALONSRC}/distributed-process-trans || exit 6
${CBLRPM} srpms ${HALONSRC}/distributed-process-scheduler || exit 6
${CBLRPM} srpms ${HALONSRC}/cep/cep || exit 6
${CBLRPM} srpms ${HALONSRC}/consensus || exit 6
${CBLRPM} srpms ${HALONSRC}/consensus-paxos || exit 6
${CBLRPM} srpms ${HALONSRC}/distributed-commands || exit 6
${CBLRPM} srpms ${HALONSRC}/replicated-log || exit 6
${CBLRPM} srpms ${HALONSRC}/halon || exit 6
${CBLRPM} srpms ${HALONSRC}/sspl || exit 6
${CBLRPM} srpms ${HALONSRC}/rpclite || exit 108
${CBLRPM} srpms ${HALONSRC}/confc || exit 107
${CBLRPM} srpms ${HALONSRC}/mero-halon -fmero || exit 109

# by the time you reach here, you should have
# the RPMs, SRPMs, and .spec files in /root/rpmbuild


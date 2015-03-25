FROM centos:centos7

# this fedora image starts without $HOME set right...
# fix that...
ENV HOME /root
ENV LANG en_US.UTF-8

# general build stuff
RUN yum install -y make

# these are for building RPMs
RUN yum install -y git rpm-build chrpath yum-utils dnf

WORKDIR /etc/yum.repos.d
RUN curl -O https://copr.fedoraproject.org/coprs/petersen/ghc-7.8.4/repo/epel-7/petersen-ghc-7.8.4-epel-7.repo

# these are a restricted set of GHC packages
# from rawhide; the overall "ghc" package is not
# installed because it brings in a lot of libraries
# that we want our own version of.
# some ofthese are dependencies for ghc-Cabal-devel that
#  are not properly represented in the metadata.
RUN yum install -y ghc-compiler cabal-install ghc-array-devel ghc-binary-devel ghc-bytestring-devel ghc-containers-devel ghc-deepseq-devel ghc-template-haskell-devel ghc-pretty-devel ghc-directory-devel ghc-filepath-devel ghc-process-devel ghc-time-devel ghc-unix-devel ghc-old-locale-devel ghc-Cabal-devel

RUN yum install -y python3-requests python-requests python-dnf python-kickstart

# this is needed as a dependency for the Haskell
# zlib cabal package, which needs to be manually
# expressed here because the cabal packaging does
# not express it
RUN yum install -y zlib-devel

RUN mkdir -p /h
RUN cabal update

# for some of the subsequent steps, we need
# to ssh to places.
RUN mkdir    -p /root/.ssh

ADD id_rsa /root/.ssh/id_rsa
ADD known_hosts /root/.ssh/known_hosts
RUN chmod go-rwx /root/.ssh/id_rsa

# first, get a more recent version of cabal
# than the distro provides.
# This needs to happen before cabal-rpm is
# built so that it has a recent cabal
# library in it. (I think?)

# use the same sandbox for both so cabal-rpm has
# access to the cabal dev libraries.
RUN mkdir /h/cabal-installers
WORKDIR /h/cabal-installers

RUN cabal sandbox init --sandbox=/h/cabal-installers
RUN cabal install cabal-install
RUN rpm --erase cabal-install
RUN cp -v /h/cabal-installers/bin/cabal /usr/local/bin/

WORKDIR /h

RUN git clone git@github.com:tweag/cabal-rpm.git
WORKDIR /h/cabal-rpm

RUN cabal sandbox init --sandbox=/h/cabal-installers
RUN cabal install
RUN cp /h/cabal-installers/bin/cblrpm /usr/local/bin/

WORKDIR /h

# so now we have a recent cabal and cabal-rpm tool
# installed (not using RPM)

RUN git clone git@github.com:tweag/halon.git
WORKDIR /h/halon

# we're using ghc 7.8.4 but the halon repo is set for 7.8.3
# which has a slightly different base constraint.
RUN sed -i 's/base ==4.7.0.1/base ==4.7.0.2/' /h/halon/cabal.config

RUN git submodule update --init --recursive

RUN mkdir -p /root/rpmbuild/SOURCES
RUN mkdir -p /root/rpmbuild/SPECS
WORKDIR /root/rpmbuild/SPECS

# we need recent cabal build libraries for at least
# one package, distributive, globally accessible.
RUN cblrpm install Cabal

# the packages neeed to be built in approximately
# this order
RUN cblrpm install /h/halon/vendor/clock
RUN cblrpm install /h/halon/vendor/options-schema
RUN cblrpm install /h/halon/vendor/tasty-files
RUN cblrpm install /h/halon/vendor/network-transport-tcp
RUN cblrpm install /h/halon/vendor/distributed-static
RUN cblrpm install /h/halon/vendor/distributed-process
RUN cblrpm install /h/halon/cep/cep
RUN cblrpm install /h/halon/distributed-process-trans
RUN cblrpm install /h/halon/distributed-process-scheduler
RUN cblrpm install /h/halon/consensus
RUN cblrpm install /h/halon/consensus-paxos
RUN cblrpm install /h/halon/distributed-commands
RUN cblrpm install /h/halon/replicated-log
RUN cblrpm install /h/halon/halon
RUN cblrpm install /h/halon/sspl
RUN cblrpm install /h/halon/mero-halon

# by the time you reach here, you should have
# the RPMs, SRPMs, and .spec files in /root/rpmbuild


FROM centos:centos7

# this fedora image starts without $HOME set right...
# fix that...
ENV HOME /root
ENV LANG en_US.UTF-8


RUN yum install -y yum-utils

WORKDIR /etc/yum.repos.d
# RUN curl -O https://copr.fedoraproject.org/coprs/petersen/ghc-7.8.4/repo/epel-7/petersen-ghc-7.8.4-epel-7.repo
# RUN curl -O https://copr.fedoraproject.org/coprs/petersen/ghc-7.10.1/repo/epel-7/petersen-ghc-7.10.1-epel-7.repo
RUN curl -O https://copr.fedoraproject.org/coprs/petersen/ghc-7.10.2/repo/epel-7/petersen-ghc-7.10.2-epel-7.repo
RUN yum-config-manager --disable petersen-ghc-7.10.2

# for leveldb
RUN yum install -y epel-release
RUN yum-config-manager --disable epel

# general build stuff
RUN yum install -y make git rpm-build chrpath dnf

# these are a restricted set of GHC packages
# from rawhide; the overall "ghc" package is not
# installed because it brings in a lot of libraries
# that we want our own version of.
# some ofthese are dependencies for ghc-Cabal-devel that
#  are not properly represented in the metadata.
RUN yum install -y --enablerepo=petersen-ghc-7.10.2 ghc-compiler ghc-array-devel ghc-binary-devel ghc-bytestring-devel ghc-containers-devel ghc-deepseq-devel ghc-template-haskell-devel ghc-pretty-devel ghc-directory-devel ghc-filepath-devel ghc-process-devel ghc-time-devel ghc-unix-devel ghc-old-locale-devel ghc-Cabal-devel ghc-transformers-devel

RUN yum install -y python3-requests python-requests python-dnf python-kickstart

# this is needed as a dependency for the Haskell
# zlib cabal package, which needs to be manually
# expressed here because the cabal packaging does
# not express it
RUN yum install -y zlib-devel

# this is needed for leveldb haskell package
RUN yum install -y --enablerepo=epel leveldb-devel

RUN mkdir -p /h

# for some of the subsequent steps, we need
# to ssh to places.
RUN mkdir    -p /root/.ssh

ADD id_rsa /root/.ssh/id_rsa
ADD known_hosts /root/.ssh/known_hosts
RUN chmod go-rwx /root/.ssh/id_rsa


WORKDIR /h

# so now we have a recent cabal and cabal-rpm tool
# installed (not using RPM)

# ENV BLAH change-this-to-stop-caching

RUN git clone git@github.com:tweag/halon.git

WORKDIR /h/halon

# If you want to build from a different branch,
# this is the place to switch branches:
# RUN git checkout rpm/build-with-rich

RUN git submodule update --init --recursive
ENV HALONSRC /h/halon

WORKDIR /h/halon/docker/rpm
ENV WORKDIR /h/cabal-installers

RUN ./bootstrap-build-tools.sh

# this mv because the bootstrap-build-tools has
# messed up environment variables for install
# targets
# RUN mv /h/cabal-installers/cabal-installers/bin/* /h/cabal-installers/bin/

ENV WORKDIR /h

RUN yum install -y autoconf

# need to remove this so that it does not
# attempt to get packaged by cblrpm -- because
# we at least don't have permissions for some
# as a different user, and also because it
# bloats the SRPM with buildcruft.
RUN rm -rfv /h/cabal-installers/cabal/Cabal-1.22.3.999/dist

RUN useradd srpmbuilder

RUN chown -R srpmbuilder /h/halon

USER srpmbuilder
ENV HOME /home/srpmbuilder

ENV WORKDIR /h
ENV HALONSRC /h/halon

RUN mkdir -p /home/srpmbuilder/rpmbuild/SOURCES
RUN mkdir -p /home/srpmbuilder/rpmbuild/SPECS
RUN mkdir -p /home/srpmbuilder/rpmbuild/SRPMS

RUN /h/cabal-installers/bin/cabal update
RUN /h/halon/docker/rpm/build-with-cblrpm.sh

# by the time you reach here, you should have
# the SRPMs /root/rpmbuild/SRPM.
# They can be built with mockchain, in
# order of creation time.

USER root

RUN yum -y install pcre-devel
RUN yum -y install --enablerepo=petersen-ghc-7.10.2 cabal-install
RUN mkdir /h/installed-rpms
WORKDIR /home/srpmbuilder/rpmbuild/SRPMS
RUN cat buildorder.txt | while read rpm; do echo DOCKERFILE BUILD $rpm ; rpmbuild --rebuild $(ls halon-$rpm-* | grep halon-$rpm-[0-9]) ; echo DOCKERFILE INSTALL $rpm ; rpm --install -vh ../RPMS/x86_64/* ; echo DOCKERFILE MOVE ; mv -v ../RPMS/x86_64/* /h/installed-rpms ; done


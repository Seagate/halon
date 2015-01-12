FROM ubuntu:14.04
MAINTAINER ben.clifford@tweag.io
# 14.04 is latest Long Term Support (LTS) ubuntu at time of writing

ENV HOME /root
# because otherwise HOME points to / but ~root points to /root

# the default ubuntu docker container does not come with
# locales...
ENV LANG en_GB.UTF-8
RUN locale-gen en_GB.UTF-8

RUN apt-get install -y curl bzip2

RUN curl -O https://downloads.haskell.org/~ghc/7.8.3/ghc-7.8.3-x86_64-unknown-linux-deb7.tar.bz2

RUN bunzip2 ghc-7.8.3-x86_64-unknown-linux-deb7.tar.bz2
RUN tar xf ghc-7.8.3-x86_64-unknown-linux-deb7.tar

RUN apt-get install -y libgmp-dev libgmp10
RUN apt-get install -y make

WORKDIR ./ghc-7.8.3
RUN ./configure
RUN make install

# needed for cabal-install zlib dependency
RUN apt-get install -y zlib1g-dev

WORKDIR /
RUN curl -O https://www.haskell.org/cabal/release/cabal-install-1.20.0.3/cabal-install-1.20.0.3.tar.gz
RUN tar xzf cabal-install-1.20.0.3.tar.gz
WORKDIR /cabal-install-1.20.0.3
RUN ./bootstrap.sh

RUN ln -vs /root/.cabal/bin/cabal /usr/local/bin/cabal

# clone repo
RUN apt-get install -y git

# this will need github permissions...
RUN mkdir /root/.ssh
ADD id_rsa /root/.ssh/
ADD known_hosts /root/.ssh/

RUN apt-get install -y libgenders0-dev

WORKDIR /
RUN git clone git@github.com:tweag/halon.git
WORKDIR /halon

# update and install the dependencies
# into sandbox
RUN cabal update
RUN git submodule update --init --recursive
RUN make dep

# build halon, which will also run some tests.

RUN make


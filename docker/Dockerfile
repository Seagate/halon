ARG  CENTOS_RELEASE=latest
FROM registry.gitlab.mero.colo.seagate.com/mero/mero:${CENTOS_RELEASE}

ADD halon-dist.tar.gz .

RUN cp halon/docker/stack.repo /etc/yum.repos.d/

RUN yum -y install \
           binutils-devel \
           gmp-devel \
           leveldb-devel \
           libgenders-devel \
           libyaml-devel \
           ncurses-devel \
           pcre-devel \
           stack

# ghc-options should match the defaults from `h0` script (see DEFAULT_GHC_OPTS)
RUN cd halon \
    && stack build --only-dependencies --ghc-options='-g -j2 -O0' \
    && cd .. \
    && rm -rf halon

# fix read permissions for some files that created with user-only access
RUN find ~/.stack \! -perm -o=r -exec chmod a+r '{}' \; -print

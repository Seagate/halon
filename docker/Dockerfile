#
# Builder image
#

ARG  CENTOS_RELEASE=latest
FROM registry.gitlab.mero.colo.seagate.com/mero/mero:${CENTOS_RELEASE} as halon-deps-builder

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

RUN cd halon \
    && stack setup \
    && stack build --only-dependencies

# fix read permissions for some files that created with user-only access
RUN find ~/.stack \! -perm -o=r -exec chmod a+r '{}' \; -print

#
# Final image
#

ARG  CENTOS_RELEASE=latest
FROM registry.gitlab.mero.colo.seagate.com/mero/mero:${CENTOS_RELEASE}

COPY --from=halon-deps-builder /etc/yum.repos.d/stack.repo /etc/yum.repos.d/
COPY --from=halon-deps-builder /root/.stack .stack/

RUN yum -y install \
           binutils-devel \
           gmp-devel \
           leveldb-devel \
           libgenders-devel \
           libyaml-devel \
           ncurses-devel \
           pcre-devel \
           stack

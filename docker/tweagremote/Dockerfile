FROM centos:centos7
MAINTAINER benc@cqx.ltd.uk

ENV HOME /root
# because otherwise HOME points to / but ~root points to /root

ENV LANG en_GB.UTF-8

RUN yum install --assumeyes openssh-server passwd openssh-clients hostname psmisc iptables

RUN curl -O http://www.mirrorservice.org/sites/dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
RUN rpm --install epel-release-7-5.noarch.rpm
RUN yum install --assumeyes leveldb

RUN /usr/sbin/sshd-keygen
ADD authorized_keys /root/.ssh/
RUN chown root.root /root/.ssh/authorized_keys
RUN chmod go-w /root/.ssh/authorized_keys

RUN sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

RUN adduser dev
RUN mkdir /home/dev/.ssh
RUN chown dev.dev /home/dev/.ssh
ADD authorized_keys /home/dev/.ssh/
RUN chown dev.dev /home/dev/.ssh/authorized_keys


ADD id_rsa /home/dev/.ssh/
RUN chmod go-w /home/dev/.ssh/authorized_keys


RUN chown dev.dev /home/dev/.ssh/id_rsa
RUN chmod go-rwx /home/dev/.ssh/id_rsa
RUN echo IdentityFile /home/dev/.ssh/id_rsa >> /home/dev/.ssh/config
RUN chown dev.dev /home/dev/.ssh/config

RUN cat /home/dev/.ssh/authorized_keys
RUN ls -l /home/dev/.ssh/
RUN ls -l /home/dev/.ssh/authorized_keys

RUN passwd -fu dev

RUN echo UserKnownHostsFile /dev/null >> /etc/ssh/ssh_config
RUN echo StrictHostKeyChecking no >> /etc/ssh/ssh_config

CMD /usr/sbin/sshd -D

FROM centos:centos7
MAINTAINER benc@cqx.ltd.uk

ENV HOME /root
# because otherwise HOME points to / but ~root points to /root

ENV LANG en_GB.UTF-8

RUN yum install --assumeyes openssh-server initscripts
RUN yum install --assumeyes passwd
RUN yum install --assumeyes openssh-clients
RUN yum install --assumeyes hostname
RUN yum install --assumeyes psmisc

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

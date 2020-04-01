# build number
%define h_build_num  %(test -n "$build_number" && echo "$build_number" || echo 1)

# mero git revision
#   assume that Mero package release has format 'buildnum_gitid_kernelver'
%define h_mero_git_rev %(rpm -q --whatprovides mero | xargs rpm -q --queryformat '%{RELEASE}' | cut -f2 -d_)

# mero version
%define h_mero_version %(rpm -q --whatprovides mero | xargs rpm -q --queryformat '%{VERSION}-%{RELEASE}')

# parallel build jobs
%define h_build_jobs_opt  %(test -n "$build_jobs" && echo "-j$build_jobs" || echo '')

Summary: halon
Name: halon
Version: %{h_version}
Release: %{h_build_num}_%{h_git_revision}_m0%{h_mero_git_rev}%{?dist}
License: All rights reserved
Group: System Environment/Daemons
Source: %{name}-%{h_version}.tar.gz

BuildRequires: binutils-devel
BuildRequires: git
BuildRequires: gmp-devel
BuildRequires: leveldb-devel
BuildRequires: libgenders-devel
BuildRequires: libyaml-devel
BuildRequires: mero
BuildRequires: mero-devel
BuildRequires: ncurses-devel
BuildRequires: pcre-devel
BuildRequires: stack

Requires: genders
Requires: gmp
Requires: leveldb
Requires: mero = %{h_mero_version}
Requires: pcre

%description
Cluster monitoring and recovery for high-availability.

%define stack() stack --no-docker --allow-different-user

%prep
%setup -qn %{name}
%{stack} setup

%build
%{stack} %{?h_build_jobs_opt} build --extra-include-dirs=/usr/include/mero --no-test

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/systemd/system
mkdir -p %{buildroot}/etc/sysconfig
mkdir -p %{buildroot}/etc/halon/role_maps
mkdir -p %{buildroot}/etc/logrotate.d
mkdir -p %{buildroot}/usr/libexec/halon
mkdir -p %{buildroot}%{_tmpfilesdir}
mkdir -p %{buildroot}%{_sharedstatedir}/halon
cp $(%{stack} path --local-install-root)/bin/halonctl %{buildroot}/usr/bin
cp mero-halon/scripts/hctl %{buildroot}/usr/bin
cp $(%{stack} path --local-install-root)/bin/halond %{buildroot}/usr/bin
cp scripts/halon-cleanup %{buildroot}/usr/libexec/halon
cp scripts/halon-rg-view %{buildroot}/usr/libexec/halon
cp mero-halon/scripts/setup-rabbitmq-perms.sh %{buildroot}/usr/libexec/halon
cp systemd/*.service %{buildroot}/usr/lib/systemd/system
cp systemd/sysconfig/halond.example %{buildroot}/etc/sysconfig
cp mero-halon/scripts/logrotate %{buildroot}/etc/logrotate.d/halon
cp mero-halon/scripts/mero_clovis_role_mappings.ede \
   %{buildroot}/etc/halon/role_maps/clovis.ede
cp mero-halon/scripts/mero_provisioner_role_mappings.ede \
   %{buildroot}/etc/halon/role_maps/prov.ede
cp mero-halon/scripts/mero_s3server_role_mappings.ede \
   %{buildroot}/etc/halon/role_maps/s3server.ede
cp mero-halon/scripts/halon_roles.yaml \
   %{buildroot}/etc/halon/role_maps/halon_role_mappings
cp mero-halon/scripts/tmpfiles.d/halond.conf %{buildroot}%{_tmpfilesdir}/halond.conf
ln -s /etc/halon/role_maps/clovis.ede %{buildroot}/etc/halon/mero_role_mappings
ln -s /etc/halon/role_maps/halon_role_mappings %{buildroot}/etc/halon/halon_role_mappings

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/halond
/usr/bin/halonctl
/usr/bin/hctl
/usr/libexec/halon/halon-cleanup
/usr/libexec/halon/halon-rg-view
/usr/libexec/halon/setup-rabbitmq-perms.sh
/usr/lib/systemd/system/halond.service
/usr/lib/systemd/system/halon-satellite.service
/usr/lib/systemd/system/halon-cleanup.service
/etc/halon/role_maps/clovis.ede
/etc/halon/role_maps/prov.ede
/etc/halon/role_maps/s3server.ede
/etc/halon/mero_role_mappings
/etc/halon/halon_role_mappings
/etc/halon/role_maps/halon_role_mappings
/etc/logrotate.d/halon
/etc/sysconfig/halond.example
%{_tmpfilesdir}/halond.conf
# %{_sharedstatedir} normally resolves to /var/lib
%{_sharedstatedir}/halon

%post
systemctl daemon-reload

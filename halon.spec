Summary: halon
Name: halon
Version: %{_gitversion}%{?dist}
Release: %{_buildnumber}
License: All rights reserved
Group: System Environment/Daemons
Source: %{name}.tar.gz

BuildRequires: binutils-devel
BuildRequires: libgenders-devel
BuildRequires: git
BuildRequires: gmp-devel
BuildRequires: leveldb-devel
BuildRequires: libyaml-devel
BuildRequires: mero
BuildRequires: mero-devel
BuildRequires: pcre-devel
BuildRequires: stack

Requires: genders
Requires: gmp
Requires: leveldb
Requires: mero
Requires: pcre

%description
Cluster monitoring and recovery for high-availability.

%define stack() stack --no-docker

%prep
%setup -qn %{name}
%{stack} setup

%build
# If snapshot deps already cached in global location use that instead
# of default stack root.
[ -d /stack ] && STACK_ROOT="--stack-root /stack"
%{stack} build $STACK_ROOT --extra-include-dirs=/usr/include/mero --flag mero-halon:mero --flag confc:mero

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/systemd/system
mkdir -p %{buildroot}/etc/halon/role_maps
mkdir -p %{buildroot}/etc/logrotate.d
mkdir -p %{buildroot}/usr/libexec/halon
mkdir -p %{buildroot}%{_tmpfilesdir}
cp $(%{stack} path --local-install-root)/bin/halonctl %{buildroot}/usr/bin
cp $(%{stack} path --local-install-root)/bin/halond %{buildroot}/usr/bin
cp $(%{stack} path --local-install-root)/bin/halon-cleanup %{buildroot}/usr/libexec/halon
cp mero-halon/scripts/setup-rabbitmq-perms.sh %{buildroot}/usr/libexec/halon
cp systemd/*.service %{buildroot}/usr/lib/systemd/system
cp mero-halon/scripts/logrotate %{buildroot}/etc/logrotate.d/halon
cp mero-halon/scripts/hctl %{buildroot}/usr/bin/hctl
cp mero-halon/scripts/mero_role_mappings.ede \
   %{buildroot}/etc/halon/role_maps/genders.ede
cp mero-halon/scripts/mero_provisioner_role_mappings.ede \
   %{buildroot}/etc/halon/role_maps/prov.ede
cp mero-halon/scripts/halon_roles.yaml \
   %{buildroot}/etc/halon/role_maps/halon_role_mappings
cp mero-halon/scripts/tmpfiles.d/halond.conf %{buildroot}%{_tmpfilesdir}/halond.conf
ln -s /etc/halon/role_maps/prov.ede %{buildroot}/etc/halon/mero_role_mappings
ln -s /etc/halon/role_maps/halon_role_mappings %{buildroot}/etc/halon/halon_role_mappings

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/halond
/usr/bin/halonctl
/usr/bin/hctl
/usr/libexec/halon/halon-cleanup
/usr/libexec/halon/setup-rabbitmq-perms.sh
/usr/lib/systemd/system/halond.service
/usr/lib/systemd/system/halon-satellite.service
/usr/lib/systemd/system/halon-cleanup.service
/etc/halon/role_maps/genders.ede
/etc/halon/role_maps/prov.ede
/etc/halon/mero_role_mappings
/etc/halon/halon_role_mappings
/etc/halon/role_maps/halon_role_mappings
/etc/logrotate.d/halon
%{_tmpfilesdir}/halond.conf

%post
systemctl daemon-reload

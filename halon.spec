Summary: halon
Name: halon
Version: %{_gitversion}%{?dist}
Release: 1
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
%{stack} build --extra-include-dirs=/usr/include/mero --flag mero-halon:mero --flag confc:mero

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/systemd/system
mkdir -p %{buildroot}/etc/halon/role_maps
cp $(%{stack} path --local-install-root)/bin/halonctl %{buildroot}/usr/bin
cp $(%{stack} path --local-install-root)/bin/halond %{buildroot}/usr/bin
cp systemd/*.service %{buildroot}/usr/lib/systemd/system
cp mero-halon/scripts/hctl %{buildroot}/usr/bin/hctl
cp mero-halon/scripts/mero_role_mappings.ede \
   %{buildroot}/etc/halon/role_maps/genders.ede
cp mero-halon/scripts/mero_provisioner_role_mappings.ede \
   %{buildroot}/etc/halon/role_maps/prov.ede
ln -s /etc/halon/role_maps/prov.ede %{buildroot}/etc/halon/mero_role_mappings

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/halond
/usr/bin/halonctl
/usr/bin/hctl
/usr/lib/systemd/system/halond.service
/usr/lib/systemd/system/halon-satellite.service
/etc/halon/role_maps/genders.ede
/etc/halon/role_maps/prov.ede
/etc/halon/mero_role_mappings

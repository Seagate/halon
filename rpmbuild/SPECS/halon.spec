Summary: halon
Name: halon
Version: 0.1
Release: 1
License: All rights reserved
Group: System Environment/Daemons
Source0: genders2yaml
Source1: halonctl
Source2: halond
Source3: halond.service
Source4: halon-satellite.service
Source5: halon-simplelocalcluster
Source6: genders.ede
Source6: prov.ede

Requires: gmp
Requires: leveldb
Requires: genders
Requires: pcre

%description
Cluster monitoring and recovery for high-availability.

%prep
rm -rf %{_builddir}/halon
rm -rf %{_builddir}/systemd
rm -rf %{_builddir}/role_maps
mkdir halon
mkdir systemd
mkdir role_maps
cp %{_sourcedir}/halonctl %{_builddir}/halon
cp %{_sourcedir}/halond %{_builddir}/halon
cp %{_sourcedir}/genders2yaml %{_builddir}/halon
cp %{_sourcedir}/halon-simplelocalcluster %{_builddir}/halon
cp %{_sourcedir}/halond.service %{_builddir}/systemd
cp %{_sourcedir}/halon-satellite.service %{_builddir}/systemd
cp %{_sourcedir}/genders.ede %{_builddir}/role_maps
cp %{_sourcedir}/prov.ede %{_builddir}/role_maps

%build
echo No build - this is a binary only release

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/systemd/system
mkdir -p %{buildroot}/etc/halon/role_maps
cp -a %{_builddir}/halon/* %{buildroot}/usr/bin
cp -a %{_builddir}/systemd/* %{buildroot}/usr/lib/systemd/system
cp -a %{_builddir}/role_maps/* %{buildroot}/etc/halon/role_maps
ln -s /etc/halon/role_maps/prov.ede %{buildroot}/etc/halon/mero_role_mappings

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/halond
/usr/bin/halonctl
/usr/bin/halon-simplelocalcluster
/usr/bin/genders2yaml
/usr/lib/systemd/system/halond.service
/usr/lib/systemd/system/halon-satellite.service
/etc/halon/role_maps/genders.ede
/etc/halon/role_maps/prov.ede
/etc/halon/mero_role_mappings

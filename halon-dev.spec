Summary: halon
Name: halon
Version: %{_gitversion}
Release: devel
License: All rights reserved
Group: Development/Tools
SOURCE0: halond
SOURCE1: halonctl
URL: http://www.xyratex.com/
Packager: Ben Clifford <ben.clifford@tweag.io>
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
Requires: leveldb

%description
%{summary}

%prep
rm -rf $RPM_BUILD_DIR/halon
rm -rf $RPM_BUILD_DIR/systemd
rm -rf $RPM_BUILD_DIR/role_maps
mkdir halon
mkdir systemd
mkdir role_maps
cp $RPM_SOURCE_DIR/halonctl $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halond $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/genders2yaml $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halon-simplelocalcluster $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/hctl $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halond.service $RPM_BUILD_DIR/systemd
cp $RPM_SOURCE_DIR/halon-satellite.service $RPM_BUILD_DIR/systemd
cp $RPM_SOURCE_DIR/role_maps/* $RPM_BUILD_DIR/role_maps

%build
echo No build - this is a binary only release

%install
rm -rf %{buildroot}
# in builddir
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/systemd/system
mkdir -p %{buildroot}/etc/halon/role_maps
cp -a $RPM_BUILD_DIR/halon/* %{buildroot}/usr/bin
cp -a $RPM_BUILD_DIR/systemd/* %{buildroot}/usr/lib/systemd/system
cp -a $RPM_BUILD_DIR/role_maps/* %{buildroot}/etc/halon/role_maps
ln -s /etc/halon/role_maps/prov.ede %{buildroot}/etc/halon/mero_role_mappings

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/halond
/usr/bin/halonctl
/usr/bin/halon-simplelocalcluster
/usr/bin/hctl
/usr/bin/genders2yaml
/usr/lib/systemd/system/halond.service
/usr/lib/systemd/system/halon-satellite.service
/etc/halon/role_maps/genders.ede
/etc/halon/role_maps/prov.ede
/etc/halon/mero_role_mappings

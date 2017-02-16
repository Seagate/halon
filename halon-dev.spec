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
rm -rf $RPM_BUILD_DIR/tmpfiles.d
mkdir halon
mkdir systemd
mkdir role_maps
mkdir tmpfiles.d
cp $RPM_SOURCE_DIR/halonctl $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halond $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halon-simplelocalcluster $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/hctl $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halon-cleanup $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/setup-rabbitmq-perms.sh $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halond.service $RPM_BUILD_DIR/systemd
cp $RPM_SOURCE_DIR/halon-satellite.service $RPM_BUILD_DIR/systemd
cp $RPM_SOURCE_DIR/halon-cleanup.service $RPM_BUILD_DIR/systemd
cp $RPM_SOURCE_DIR/role_maps/* $RPM_BUILD_DIR/role_maps
cp $RPM_SOURCE_DIR/tmpfiles.d/* $RPM_BUILD_DIR/tmpfiles.d

%build
echo No build - this is a binary only release

%install
rm -rf %{buildroot}
# in builddir
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/lib/systemd/system
mkdir -p %{buildroot}/etc/halon/role_maps
mkdir -p %{buildroot}/usr/libexec/halon
mkdir -p %{buildroot}%{_tmpfilesdir}
cp -a $RPM_BUILD_DIR/halon/halond %{buildroot}/usr/bin
cp -a $RPM_BUILD_DIR/halon/halonctl %{buildroot}/usr/bin
cp -a $RPM_BUILD_DIR/halon/halon-simplelocalcluster %{buildroot}/usr/bin
cp -a $RPM_BUILD_DIR/halon/hctl %{buildroot}/usr/bin
cp -a $RPM_BUILD_DIR/halon/halon-cleanup %{buildroot}/usr/libexec/halon
cp -a $RPM_BUILD_DIR/halon/setup-rabbitmq-perms.sh %{buildroot}/usr/libexec/halon
cp -a $RPM_BUILD_DIR/systemd/* %{buildroot}/usr/lib/systemd/system
cp -a $RPM_BUILD_DIR/role_maps/* %{buildroot}/etc/halon/role_maps
cp -a $RPM_BUILD_DIR/tmpfiles.d/* %{buildroot}%{_tmpfilesdir}
ln -s /etc/halon/role_maps/prov.ede %{buildroot}/etc/halon/mero_role_mappings
ln -s /etc/halon/role_maps/halon_role_mappings %{buildroot}/etc/halon/halon_role_mappings


%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/halond
/usr/bin/halonctl
/usr/bin/halon-simplelocalcluster
/usr/bin/hctl
/usr/libexec/halon/halon-cleanup
/usr/libexec/halon/setup-rabbitmq-perms.sh
/usr/lib/systemd/system/halond.service
/usr/lib/systemd/system/halon-satellite.service
/usr/lib/systemd/system/halon-cleanup.service
/etc/halon/role_maps/clovis.ede
/etc/halon/role_maps/prov.ede
/etc/halon/mero_role_mappings
/etc/halon/halon_role_mappings
/etc/halon/role_maps/halon_role_mappings
%{_tmpfilesdir}/halond.conf

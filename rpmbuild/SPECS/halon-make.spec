Summary: halon
Name: halon
Version: 0.17
Release: 1
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
mkdir halon
mkdir systemd
cp $RPM_SOURCE_DIR/halonctl $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halond $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halon-simplelocalcluster $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halond.service $RPM_BUILD_DIR/systemd

%build
echo No build - this is a binary only release

%install
rm -rf %{buildroot}
# in builddir
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/usr/lib/systemd/system
cp -a $RPM_BUILD_DIR/halon/* %{buildroot}/usr/local/bin
cp -a $RPM_BUILD_DIR/systemd/* %{buildroot}/usr/lib/systemd/system

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/local/bin/halond
/usr/local/bin/halonctl
/usr/local/bin/halon-simplelocalcluster
/usr/lib/systemd/system/halond.service


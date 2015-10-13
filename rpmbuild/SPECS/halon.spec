Summary: halon
Name: halon
Version: 0.14.5
Release: 1
License: All rights reserved
Group: Development/Tools
URL: http://www.xyratex.com/
Packager: Ben Clifford <ben.clifford@tweag.io>
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
Requires: halon-mero-halon
Source: halond.service

%description
%{summary}

%prep
rm -rf $RPM_BUILD_DIR/halon
mkdir -p $RPM_BUILD_DIR/systemd
cp $RPM_SOURCE_DIR/halond.service $RPM_BUILD_DIR/systemd

%build
echo No build - this is a binary only release

%install
rm -rf %{buildroot}
# in builddir
mkdir -p %{buildroot}/usr/lib/systemd/system
cp -a $RPM_BUILD_DIR/systemd/* %{buildroot}/usr/lib/systemd/system

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/lib/systemd/system/halond.service


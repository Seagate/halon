Summary: halon
Name: halon
Version: 0.2
Release: 1
License: All rights reserved
Group: Development/Tools
SOURCE0: halond
SOURCE1: halonctl
URL: http://www.xyratex.com/
Packager: Ben Clifford <ben.clifford@tweag.io>
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root

%description
%{summary}

%prep
rm -rf $RPM_BUILD_DIR/halon
mkdir halon
cp $RPM_SOURCE_DIR/halonctl $RPM_BUILD_DIR/halon
cp $RPM_SOURCE_DIR/halond $RPM_BUILD_DIR/halon

%build
echo No build - this is a binary only release

%install
rm -rf %{buildroot}
# in builddir
mkdir -p %{buildroot}/usr/bin
cp -a $RPM_BUILD_DIR/halon/* %{buildroot}/usr/bin

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
/usr/bin/halond
/usr/bin/halonctl


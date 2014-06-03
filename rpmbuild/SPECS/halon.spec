%define        __spec_install_post %{nil}
%define          debug_package %{nil}
%define        __os_install_post %{_dbpath}/brp-compress
Summary: HA demo
Name: halon
Version: 6.0
Release: 1
License: All rights reserved
Group: Development/Tools
SOURCE0 : %{name}.tar.gz
URL: http://www.xyratex.com/
Packager: Jeff Epstein <v-jeff_epstein@xyratex.com>
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
Conflicts: halon-build <= 1.0, halon-rpc <= 1.0

%define bintargets halon/mero-ha/dist/build/ha-node-agent/ha-node-agent \\\
halon/mero-ha/dist/build/ha-station/ha-station \\\
halon/mero-ha/scripts/ha \\\
halon/mero-ha/scripts/mero_call \\\
halon/mero-ha/scripts/query.inc \\\
halon/mero-ha/scripts/mkgenders

%define sharetargets halon/mero-ha/dist/build/unit-tests/unit-tests \\\
halon/mero-ha/dist/build/integration-tests/integration-tests \\\
halon/ha/dist/build/unit-tests/unit-tests \\\
halon/ha/dist/build/integration-tests/integration-tests

%description
%{summary}

%prep
rm -rf $RPM_BUILD_DIR/halon
zcat $RPM_SOURCE_DIR/halon.tar.gz | tar -xf -

%build
make LANG=$HA_BUILD_LANG ROOT_DIR=../../.. -e -C halon DEBUG=t dep
make LANG=$HA_BUILD_LANG -C halon -e DEBUG=t install

%install
rm -rf %{buildroot}
# in builddir
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/halon/tests
cp -a %{bintargets} %{buildroot}/usr/bin
for fname in %{sharetargets};
do
  cp -a $fname %{buildroot}/usr/share/halon/tests/$( echo $fname | cut -d / -f 2 )-$(basename ${fname})
done

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
# %config(noreplace) %{_sysconfdir}/%{name}/%{name}.conf
%{_bindir}/*
/usr/bin/ha
/usr/bin/ha-node-agent
/usr/bin/ha-station
/usr/bin/mero_call
/usr/bin/query.inc
/usr/bin/mkgenders
/usr/share/halon/tests/*

%changelog
* Fri Jul 31 2013 Jeff Epstein <v-jeff_epstein@xyratex.com> 6.0-1
- Sprint 9 build.
* Fri Jun 28 2013 Jeff Epstein <v-jeff_epstein@xyratex.com> 5.0-1
- Sprint 8 build.
* Fri May 31 2013 Vladimir Komendantsky <vladimir.komendantsky@parsci.com> 4.0-1
- Sprint 7 build.
* Wed May 1 2013 Vladimir Komendantsky <vladimir.komendantsky@parsci.com> 3.0-2
- Updated usage info in the ha script.
* Wed May 1 2013 Vladimir Komendantsky <vladimir.komendantsky@parsci.com> 3.0-1
- Sprint 6 RPM build.
* Thu Mar 28 2013 Vladimir Komendantsky <vladimir.komendantsky@parsci.com> 2.0-1
- Sprint 5 RPM build. The package is renamed from halon-rpc to halon.
* Fri Feb 22 2013 Vitalii Skakun <vitalii.skakun@parsci.com> 1.0-1
- Sprint 4 RPM build.

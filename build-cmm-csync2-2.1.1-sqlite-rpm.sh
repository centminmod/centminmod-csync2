#!/bin/bash

set -e

# Set variables
CSYNC2_VER=2.1.1

# Determine DISTTAG based on OS release
if grep -q "release 8" /etc/redhat-release; then
    DISTTAG='el8'
    POSTGRESQL_VERSION=15
    CRB_REPO="powertools"
# MariaDB instead of Oracle MySQL
    MDB_ARCHIVES_PUBKEY='https://supplychain.mariadb.com/MariaDB-Server-GPG-KEY'
cat > /etc/yum.repos.d/mariadb.repo <<EOF
[mariadb]
name = MariaDB
baseurl = https://archive.mariadb.org/mariadb-10.3/yum/centos8-amd64
module_hotfixes=1
gpgkey=${MDB_ARCHIVES_PUBKEY}
gpgcheck=1
EOF
  rpm --import "$MDB_ARCHIVES_PUBKEY"
  yum -q -y module disable mariadb mysql
elif grep -q "release 9" /etc/redhat-release; then
    DISTTAG='el9'
    POSTGRESQL_VERSION=15
    CRB_REPO="crb"
# MariaDB instead of Oracle MySQL
    MDB_ARCHIVES_PUBKEY='https://supplychain.mariadb.com/MariaDB-Server-GPG-KEY'
cat > /etc/yum.repos.d/mariadb.repo <<EOF
[mariadb]
name = MariaDB
baseurl = https://archive.mariadb.org/mariadb-10.5/yum/rhel9-amd64
module_hotfixes=1
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
exclude=MariaDB-Galera-server
EOF
  rpm --import "$MDB_ARCHIVES_PUBKEY"
  yum -q -y module disable mariadb
fi

# Enable repositories: CRB and EPEL
dnf clean all
dnf install -y epel-release
dnf config-manager --set-enabled ${CRB_REPO}

# Enable PostgreSQL module and install postgresql-server-devel
dnf module enable postgresql:${POSTGRESQL_VERSION} -y &&
dnf install -y postgresql-server-devel

# Install dependencies
dnf groupinstall 'Development Tools' -y
dnf install --allowerasing -y \
  libpq-devel \
  wget \
  binutils \
  rpm-build \
  gcc \
  make \
  cmake \
  tar \
  curl \
  gnupg2 \
  openssl-devel \
  zlib-devel \
  sqlite \
  sqlite-devel \
  sqlite-libs \
  xz \
  xz-devel \
  libtool \
  pkgconfig \
  automake \
  glib2-devel \
  bison \
  flex \
  libnet-devel \
  libgcrypt-devel \
  gnutls-devel \
  librsync-devel \
  MariaDB-devel \
  texlive \
  texlive-latex

# Download the master branch source from GitHub
wget "https://github.com/centminmod/csync2/archive/refs/heads/2.1.tar.gz" -O "csync2-${CSYNC2_VER}.tar.gz"
tar -xzf "csync2-${CSYNC2_VER}.tar.gz"

# Rename the extracted directory to match the spec file's expectation
mv csync2-2.1 csync2-${CSYNC2_VER}
cd "csync2-${CSYNC2_VER}"

# Prepare for building the RPM
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Create the spec file
cat << EOF > ~/rpmbuild/SPECS/csync2.spec
#
# spec file for package csync2
#
# Copyright 2004-2020 LINBIT, Vienna, Austria
#
# SPDX-License-Identifier: GPL-2.0-or-later

%global cdversion 2.1

Summary:        Cluster synchronization tool
License:        GPL-2.0-or-later
Group:          Productivity/Clustering/HA

Name:           csync2
Version: 2.1.1
Release: 1%{?dist}
URL:            https://github.com/centminmod/csync2#readme
Source0: %{name}-%{version}.tar.gz

BuildRequires:  autoconf
BuildRequires:  automake
BuildRequires:  bison
BuildRequires:  flex
BuildRequires:  gnutls-devel
BuildRequires:  librsync-devel
BuildRequires:  hostname
# openssl required at build time due to rpmlint checks which run postinstall script which uses openssl
BuildRequires:  openssl
BuildRequires:  pkgconfig
BuildRequires:  sqlite-custom-devel
Requires:       sqlite-custom-libs
Requires:       openssl
Requires:       sqlite-custom
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
%if 0%{?suse_version} >= 1210 || 0%{?rhel} >= 7
BuildRequires:  systemd-rpm-macros
%endif

BuildRoot:      %{_tmppath}/%{name}-%{version}-build

%description
Csync2 is a cluster synchronization tool. It can be used to keep files on
multiple hosts in a cluster in sync. Csync2 can handle complex setups with
much more than just 2 hosts, handle file deletions and can detect conflicts.
It is expedient for HA-clusters, HPC-clusters, COWs and server farms.

%prep
%setup -n csync2-%{cdversion}
%{?suse_update_config:%{suse_update_config}}

%build
export CPPFLAGS="-I/opt/custom-sqlite/include -I/usr/include"
export RPM_OPT_FLAGS="\$RPM_OPT_FLAGS -Wno-format-truncation -Wno-misleading-indentation"
export CFLAGS="\$RPM_OPT_FLAGS -I/usr/kerberos/include"

export PKG_CONFIG_PATH="/opt/sqlite-custom/lib/pkgconfig:\$PKG_CONFIG_PATH"
export CFLAGS="-I/opt/sqlite-custom/include \$CFLAGS"
export LDFLAGS="-L/opt/sqlite-custom/lib -Wl,-rpath,/opt/sqlite-custom/lib \$LDFLAGS"

if ! [ -f configure ]; then ./autogen.sh; fi
%configure --enable-systemd --enable-mysql --enable-postgres --disable-sqlite --enable-sqlite3 \
  --sysconfdir=%{_sysconfdir}/csync2 --docdir=%{_docdir}/%{name}

make %{?_smp_mflags}

%preun
systemctl --no-reload disable csync2.socket >/dev/null 2>&1 || :
systemctl stop csync2.socket >/dev/null 2>&1 || :
systemctl --no-reload disable csync2@.service >/dev/null 2>&1 || :
systemctl stop csync2@.service >/dev/null 2>&1 || :

%postun 
systemctl daemon-reload >/dev/null 2>&1 || :

%install
mkdir -p %{buildroot}%{_localstatedir}/lib/csync2
mkdir -p %{buildroot}%{_docdir}/csync2
mkdir -p %{buildroot}%{_sysconfdir}/csync2
install -D -m 644 csync2.cfg %{buildroot}%{_sysconfdir}/csync2/csync2.cfg
install -D -m 644 csync2.socket %{buildroot}%{_unitdir}/csync2.socket
install -D -m 644 csync2@.service %{buildroot}%{_unitdir}/csync2@.service
install -m 644 AUTHORS %{buildroot}%{_docdir}/csync2/AUTHORS
install -m 644 AUTHORS.adoc %{buildroot}%{_docdir}/csync2/AUTHORS.adoc
install -m 644 README %{buildroot}%{_docdir}/csync2/README
install -m 644 README.adoc %{buildroot}%{_docdir}/csync2/README.adoc

%make_install
mkdir -p %{buildroot}%{_localstatedir}/lib/csync2
install -m 644 doc/csync2.adoc %{buildroot}%{_docdir}/csync2/csync2.adoc
install -m 644 doc/csync2-quickstart.adoc %{buildroot}%{_docdir}/csync2/csync2-quickstart.adoc

%clean
[ "\$RPM_BUILD_ROOT" != "/" ] && [ -d \$RPM_BUILD_ROOT ] && rm -rf \$RPM_BUILD_ROOT
make clean

#%pre
#systemctl preset csync2.socket >/dev/null 2>&1 || :

%post
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl preset csync2.socket >/dev/null 2>&1 || :
systemctl preset csync2@.service >/dev/null 2>&1 || :
if ! grep -q "^csync2" %{_sysconfdir}/services ; then
    echo "csync2          30865/tcp" >>%{_sysconfdir}/services
fi

%files
%config(noreplace) %{_sysconfdir}/csync2/csync2.cfg
%defattr(-,root,root)
%doc %{_docdir}/csync2/*
%doc %{_docdir}/csync2/AUTHORS
%doc %{_docdir}/csync2/AUTHORS.adoc
%doc %{_docdir}/csync2/ChangeLog
%doc %{_docdir}/csync2/COPYING
%doc %{_docdir}/csync2/csync2-quickstart.adoc
%doc %{_docdir}/csync2/csync2.adoc
%doc %{_docdir}/csync2/README
%doc %{_docdir}/csync2/README.adoc
%doc %{_mandir}/man1/csync2.1.gz
%{_sbindir}/csync2
%{_sbindir}/csync2-compare
%{_unitdir}/csync2.socket
%{_unitdir}/csync2@.service
%{_var}/lib/csync2

%changelog
* Fri Sep 18 2020 Lars Ellenberg <lars.ellenberg@linbit.com> - 2.1-1
- New upstream release

* Tue Jan 27 2015 Lars Ellenberg <lars.ellenberg@linbit.com> - 2.0-1
- New upstream release
EOF

# Modify the Version field to 2.1
sed -i "s/^Version:.*/Version: ${CSYNC2_VER}/" ~/rpmbuild/SPECS/csync2.spec

cp "../csync2-${CSYNC2_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Add new changelog entry
sed -i '/^%changelog/a \* '"$(date +"%a %b %d %Y")"' George Liu <centminmod.com> - '"${CSYNC2_VER}"'-1\n- Update for EL8/EL9 OSes\n' ~/rpmbuild/SPECS/csync2.spec

echo
cat ~/rpmbuild/SPECS/csync2.spec
echo

# Build the RPM using rpmbuild
rpmbuild -ba ~/rpmbuild/SPECS/csync2.spec --define "dist .${DISTTAG}"

echo
ls -lah ~/rpmbuild/RPMS/x86_64/
echo
ls -lah ~/rpmbuild/SRPMS/
echo

# Move the built RPMs and SRPMs to the workspace for GitHub Actions
mkdir -p /workspace/rpms
cp ~/rpmbuild/SPECS/csync2.spec /workspace/rpms/
cp ~/rpmbuild/RPMS/x86_64/*.rpm /workspace/rpms/ || echo "No RPM files found in ~/rpmbuild/RPMS/x86_64/"
cp ~/rpmbuild/SRPMS/*.rpm /workspace/rpms/ || echo "No SRPM files found in ~/rpmbuild/SRPMS/"

# Verify the copied files
ls -lah /workspace/rpms/

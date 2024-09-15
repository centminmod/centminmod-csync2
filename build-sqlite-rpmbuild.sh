#!/bin/bash

set -e

# Set variables
SQLITE_VER=3.46.1
SQLITE_DOWNLOAD_VER=3460100
CUSTOM_PREFIX="/opt/sqlite-custom"

# Determine DISTTAG based on OS release
if grep -q "release 8" /etc/redhat-release; then
    DISTTAG='el8'
    CRB_REPO="powertools"
    dnf module enable python39 -y
    dnf install python39 python39-devel -y
    alternatives --set python /usr/bin/python3.9
    alternatives --set python3 /usr/bin/python3.9
elif grep -q "release 9" /etc/redhat-release; then
    DISTTAG='el9'
    CRB_REPO="crb"
    dnf install python3 python3-devel -y
fi

# Enable repositories: CRB and EPEL
dnf install -y epel-release
dnf config-manager --set-enabled ${CRB_REPO}

# Install dependencies
dnf groupinstall 'Development Tools' -y
dnf install -y \
  sqlite \
  wget \
  rpm-build \
  binutils \
  gcc \
  make \
  readline-devel \
  ncurses-devel \
  zlib-devel \
  tcl-devel \
  openssl-devel \
  libicu-devel \
  libedit-devel

# Download the SQLite source
wget "https://www.sqlite.org/2024/sqlite-autoconf-${SQLITE_DOWNLOAD_VER}.tar.gz" -O "sqlite-${SQLITE_VER}.tar.gz"
tar -xzf "sqlite-${SQLITE_VER}.tar.gz"

# Prepare for building the RPM
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Create the spec file
cat << EOF > ~/rpmbuild/SPECS/sqlite-custom.spec
%define debug_package %{nil}
%define _prefix ${CUSTOM_PREFIX}

Summary: SQLite is a self-contained, high-reliability, embedded, full-featured, public-domain, SQL database engine
Name: sqlite-custom
Version: ${SQLITE_VER}
Release: 1%{?dist}
License: Public Domain
URL: https://www.sqlite.org/
Source0: sqlite-%{version}.tar.gz
BuildRequires: gcc
BuildRequires: readline-devel
BuildRequires: ncurses-devel
BuildRequires: zlib-devel
BuildRequires: tcl-devel
BuildRequires: openssl-devel
BuildRequires: libicu-devel
BuildRequires: libedit-devel
Requires: %{name}-libs%{?_isa} = %{version}-%{release}

%description
SQLite is a C library that implements an SQL database engine. A large
subset of SQL92 is supported. A complete database is stored in a
single disk file. The API is designed for convenience and ease of use.
Applications that link against SQLite can enjoy the power and
flexibility of an SQL database without the administrative hassles of
supporting a separate database server.

%package libs
Summary: Shared library for SQLite
Provides: sqlite-custom-libs = %{version}-%{release}
Provides: sqlite-custom-libs%{?_isa} = %{version}-%{release}
Provides: libsqlite3.so.0()(64bit)

%description libs
This package contains the shared library for SQLite.

%package devel
Summary: Development files for SQLite
Requires: %{name}-libs%{?_isa} = %{version}-%{release}
Requires: pkgconfig

%description devel
This package contains the header files and development documentation
for sqlite. If you like to develop programs using sqlite, you will need
to install sqlite-custom-devel.

%prep
%setup -q -n sqlite-autoconf-${SQLITE_DOWNLOAD_VER}

%build
export CFLAGS="%{optflags} -O3 -flto -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_SECURE_DELETE=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 -DSQLITE_ENABLE_FTS3_TOKENIZER=1"
export LDFLAGS="%{?__global_ldflags} -flto"
%configure \
    --enable-threadsafe \
    --enable-readline \
    --enable-dynamic-extensions \
    --enable-fts3 \
    --enable-fts4 \
    --enable-fts5 \
    --enable-rtree \
    --enable-session \
    --enable-shared \
    --enable-static

make %{?_smp_mflags}

%install
rm -rf \$RPM_BUILD_ROOT
make install DESTDIR=\$RPM_BUILD_ROOT

# Strip debug info
%{__strip} --strip-debug \$RPM_BUILD_ROOT%{_libdir}/*.so*
%{__strip} --strip-unneeded \$RPM_BUILD_ROOT%{_bindir}/*

# Remove libtool archives
find \$RPM_BUILD_ROOT -name '*.la' -exec rm -f {} ';'

%clean
rm -rf \$RPM_BUILD_ROOT

%post libs -p /sbin/ldconfig
%postun libs -p /sbin/ldconfig

%files
%defattr(-,root,root,-)
%{_bindir}/*
%{_mandir}/man1/*

%files libs
%defattr(-,root,root,-)
%{_libdir}/*.so.*

%files devel
%defattr(-,root,root,-)
%{_includedir}/*.h
%{_libdir}/*.so
%{_libdir}/*.a
%{_libdir}/pkgconfig/*.pc

%changelog
* $(date "+%a %b %d %Y") George Liu <centminmod.com> - ${SQLITE_VER}-1
- Automated build for SQLite ${SQLITE_VER}
- Enabled FTS3, FTS4, FTS5, RTree, Thread-safe, Dynamic extensions, Readline, and Session
- Added CFLAGS for additional features and optimizations
- Installed in custom prefix ${CUSTOM_PREFIX}
EOF

# Copy the source to rpmbuild/SOURCES
cp "sqlite-${SQLITE_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Build the RPM
rpmbuild -ba ~/rpmbuild/SPECS/sqlite-custom.spec --define "dist .${DISTTAG}"

echo "RPMs built:"
ls -lah ~/rpmbuild/RPMS/x86_64/
echo
echo "Source RPM built:"
ls -lah ~/rpmbuild/SRPMS/
echo

# Move the built RPMs and SRPMs to the workspace for GitHub Actions
mkdir -p /workspace/rpms
cp ~/rpmbuild/SPECS/sqlite-custom.spec /workspace/rpms/
cp ~/rpmbuild/RPMS/x86_64/*.rpm /workspace/rpms/ || echo "No RPM files found in ~/rpmbuild/RPMS/x86_64/"
cp ~/rpmbuild/SRPMS/*.rpm /workspace/rpms/ || echo "No SRPM files found in ~/rpmbuild/SRPMS/"

# Verify the copied files
echo "Contents of /workspace/rpms:"
ls -lah /workspace/rpms/

# Optional: Check contents of built RPMs
for rpm in /workspace/rpms/*.rpm; do
    echo "Contents of $rpm:"
    rpm -qlp $rpm
done

# Optional: Compare sizes with system packages
echo
echo "Comparing sizes with system packages:"
for pkg in sqlite sqlite-libs sqlite-devel; do
    echo "${pkg}:"
    rpm -q --queryformat "%{SIZE}\n" ${pkg} || echo "Not installed"
    rpm -qp --queryformat "%{SIZE}\n" /workspace/rpms/sqlite-custom*-${SQLITE_VER}-1.${DISTTAG}.x86_64.rpm || echo "Not found"
done

echo "Build script completed."
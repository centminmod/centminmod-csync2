#!/bin/bash

set -e

# Set variables
SQLITE_VER=3.46.1
SQLITE_DOWNLOAD_VER=3460100

# Determine DISTTAG based on OS release
if grep -q "release 8" /etc/redhat-release; then
    DISTTAG='el8'
    CRB_REPO="powertools"
elif grep -q "release 9" /etc/redhat-release; then
    DISTTAG='el9'
    CRB_REPO="crb"
fi

# Enable repositories: CRB and EPEL
dnf install -y epel-release
dnf config-manager --set-enabled ${CRB_REPO}

# Install dependencies
dnf groupinstall 'Development Tools' -y
dnf install -y \
  wget \
  rpm-build \
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
cat << EOF > ~/rpmbuild/SPECS/sqlite.spec
Summary: SQLite is a self-contained, high-reliability, embedded, full-featured, public-domain, SQL database engine
Name: sqlite
Version: ${SQLITE_VER}
Release: 1%{?dist}
License: Public Domain
URL: https://www.sqlite.org/
Source0: %{name}-%{version}.tar.gz
BuildRequires: gcc
BuildRequires: readline-devel
BuildRequires: ncurses-devel
BuildRequires: zlib-devel
BuildRequires: tcl-devel
BuildRequires: openssl-devel
BuildRequires: libicu-devel
BuildRequires: libedit-devel
Requires: readline
Requires: ncurses
Requires: zlib
Requires: openssl
Requires: libicu
Requires: libedit

%description
SQLite is a C library that implements an SQL database engine. 
Programs that link with the SQLite library can have SQL database 
access without running a separate RDBMS process.

%prep
%setup -q -n sqlite-autoconf-${SQLITE_DOWNLOAD_VER}

%build
export CFLAGS="%{optflags} -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_SECURE_DELETE=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 -DSQLITE_ENABLE_FTS3_TOKENIZER=1 -DSQLITE_ENABLE_DESERIALIZE=1"
%configure \
    --enable-static \
    --enable-fts5 \
    --enable-fts4 \
    --enable-fts3 \
    --enable-rtree \
    --enable-math \
    --enable-json1 \
    --enable-threadsafe \
    --enable-dynamic-extensions \
    --enable-readline \
    --enable-session \
    --enable-shared

make %{?_smp_mflags}

%install
rm -rf \$RPM_BUILD_ROOT
make install DESTDIR=\$RPM_BUILD_ROOT

# Remove libtool archives
find \$RPM_BUILD_ROOT -name '*.la' -exec rm -f {} ';'

%clean
rm -rf \$RPM_BUILD_ROOT

%post -p /sbin/ldconfig

%postun -p /sbin/ldconfig

%files
%defattr(-,root,root,-)
%{_bindir}/*
%{_libdir}/*.so.*
%{_mandir}/man1/*

%package devel
Summary: Development files for SQLite
Requires: %{name}%{?_isa} = %{version}-%{release}
Requires: pkg-config

%description devel
The sqlite-devel package contains libraries and header files for
developing applications that use SQLite.

%files devel
%defattr(-,root,root,-)
%{_includedir}/*.h
%{_libdir}/*.so
%{_libdir}/pkgconfig/*.pc

%changelog
* $(date "+%a %b %d %Y") Build Script <build@script.local> - ${SQLITE_VER}-1
- Automated build for SQLite ${SQLITE_VER}
- Enabled FTS5, FTS4, FTS3, RTree, Math, JSON1, Thread-safe, Dynamic extensions, Readline, and Session
- Added CFLAGS for additional features and optimizations
- Included support for ICU, OpenSSL, and libedit
EOF

# Copy the source to rpmbuild/SOURCES
cp "sqlite-${SQLITE_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Build the RPM
rpmbuild -ba ~/rpmbuild/SPECS/sqlite.spec --define "dist .${DISTTAG}"

echo
ls -lah ~/rpmbuild/RPMS/x86_64/
echo
ls -lah ~/rpmbuild/SRPMS/
echo

# Move the built RPMs and SRPMs to the workspace for GitHub Actions
mkdir -p /workspace/rpms
cp ~/rpmbuild/SPECS/sqlite.spec /workspace/rpms/
cp ~/rpmbuild/RPMS/x86_64/*.rpm /workspace/rpms/ || echo "No RPM files found in ~/rpmbuild/RPMS/x86_64/"
cp ~/rpmbuild/SRPMS/*.rpm /workspace/rpms/ || echo "No SRPM files found in ~/rpmbuild/SRPMS/"

# Verify the copied files
ls -lah /workspace/rpms/
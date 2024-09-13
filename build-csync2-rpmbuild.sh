#!/bin/bash

set -e

# Set variables
CSYNC2_VER=2.0

# Determine DISTTAG based on OS release
if grep -q "release 8" /etc/redhat-release; then
    DISTTAG='el8'
    POSTGRESQL_VERSION=15  # or choose the required version
    CRB_REPO="crb"
elif grep -q "release 9" /etc/redhat-release; then
    DISTTAG='el9'
    POSTGRESQL_VERSION=15  # or choose the required version
    CRB_REPO="crb"
fi

# Enable repositories: CRB and EPEL
dnf install -y epel-release
dnf config-manager --set-enabled ${CRB_REPO}

# Enable PostgreSQL module and install postgresql-server-devel
dnf module enable postgresql:${POSTGRESQL_VERSION} -y &&
dnf install -y postgresql-server-devel

# Install dependencies
dnf install -y \
  wget \
  rpm-build \
  gcc \
  make \
  tar \
  curl \
  gnupg2 \
  openssl-devel \
  zlib-devel \
  sqlite-devel \
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
  libgnutls-devel \
  librsync-devel \
  mysql-devel

# Download and extract the csync2 source
wget "https://github.com/LINBIT/csync2/archive/refs/tags/csync2-${CSYNC2_VER}.tar.gz" -O "csync2-${CSYNC2_VER}.tar.gz"
tar xzf "csync2-${CSYNC2_VER}.tar.gz"
cd "csync2-csync2-${CSYNC2_VER}"

# Prepare for building the RPM
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp csync2.spec ~/rpmbuild/SPECS/
cp "../csync2-${CSYNC2_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Build the RPM using rpmbuild
rpmbuild -ba ~/rpmbuild/SPECS/csync2.spec --define "dist .${DISTTAG}"

# Move the built RPM to the workspace for GitHub Actions
mkdir -p /workspace/rpms
cp ~/rpmbuild/RPMS/x86_64/*.rpm /workspace/rpms/

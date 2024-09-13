#!/bin/bash

set -e

# Set variables
CSYNC2_VER=2.1

# Determine DISTTAG based on OS release
if grep -q "release 8" /etc/redhat-release; then
    DISTTAG='el8'
    POSTGRESQL_VERSION=15
    CRB_REPO="powertools"
elif grep -q "release 9" /etc/redhat-release; then
    DISTTAG='el9'
    POSTGRESQL_VERSION=15
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
  gnutls-devel \
  librsync-devel \
  mysql-devel

# Download the master branch source from GitHub
wget "https://github.com/LINBIT/csync2/archive/refs/heads/master.zip" -O "csync2-${CSYNC2_VER}.zip"
unzip "csync2-${CSYNC2_VER}.zip"
cd "csync2-master"

# Prepare for building the RPM
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp csync2.spec ~/rpmbuild/SPECS/
cp "../csync2-${CSYNC2_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Build the RPM using rpmbuild
rpmbuild -ba ~/rpmbuild/SPECS/csync2.spec --define "dist .${DISTTAG}"

# Move the built RPM to the workspace for GitHub Actions
mkdir -p /workspace/rpms
cp ~/rpmbuild/RPMS/x86_64/*.rpm /workspace/rpms/

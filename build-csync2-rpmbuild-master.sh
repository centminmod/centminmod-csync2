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
dnf install --allowerasing -y \
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
  mysql-devel \
  texlive \
  texlive-latex

# Download the master branch source from GitHub
wget "https://github.com/LINBIT/csync2/archive/refs/heads/master.tar.gz" -O "csync2-${CSYNC2_VER}.tar.gz"
tar -xzf "csync2-${CSYNC2_VER}.tar.gz"

# Rename the extracted directory to match the spec file's expectation
mv csync2-master csync2-${CSYNC2_VER}
cd "csync2-${CSYNC2_VER}"

# Prepare for building the RPM
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp csync2.spec ~/rpmbuild/SPECS/

# Modify the Version field to 2.1
sed -i 's/^Version:.*/Version: 2.1/' ~/rpmbuild/SPECS/csync2.spec

# Modify the Release field (optional)
sed -i 's/^Release:.*/Release: 1%{?dist}/' ~/rpmbuild/SPECS/csync2.spec

# Modify the Source0 line to point to the correct tar.gz
sed -i 's/^Source0:.*/Source0: %{name}-%{version}.tar.gz/' ~/rpmbuild/SPECS/csync2.spec

cp "../csync2-${CSYNC2_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Modify the %setup line in the spec file to match the extracted directory
sed -i "s/^%setup.*/%setup -n csync2-csync2-${CSYNC2_VER}/" ~/rpmbuild/SPECS/csync2.spec
sed -i '/^export CFLAGS=/i export RPM_OPT_FLAGS="$RPM_OPT_FLAGS -Wno-format-truncation -Wno-misleading-indentation -Wno-mismatched-dealloc"' ~/rpmbuild/SPECS/csync2.spec

# Build the RPM using rpmbuild
rpmbuild -ba ~/rpmbuild/SPECS/csync2.spec --define "dist .${DISTTAG}"

# Move the built RPM to the workspace for GitHub Actions
mkdir -p /workspace/rpms
cp ~/rpmbuild/RPMS/x86_64/*.rpm /workspace/rpms/

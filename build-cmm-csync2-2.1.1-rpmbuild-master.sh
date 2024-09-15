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
  iproute \
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
cp csync2.spec ~/rpmbuild/SPECS/

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

#!/bin/bash

set -e

# Set variables
CSYNC2_VER=2.1
CSYNC2_LIBDIR=/usr

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
  gcc \
  make \
  rpmdevtools \
  tar \
  curl \
  gnupg2 \
  openssl-devel \
  zlib-devel \
  sqlite \
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
wget "https://github.com/LINBIT/csync2/archive/refs/heads/master.zip" -O "csync2-${CSYNC2_VER}.zip"
unzip "csync2-${CSYNC2_VER}.zip"

# Rename the extracted directory to match the spec file's expectation
mv csync2-master csync2-${CSYNC2_VER}
cd "csync2-${CSYNC2_VER}"

# Configure and build csync2 with the appropriate options to match the spec
export CFLAGS="-Wno-format-truncation -Wno-misleading-indentation -Wno-mismatched-dealloc"
./autogen.sh
./configure --prefix=${CSYNC2_LIBDIR} \
            --sbindir=${CSYNC2_LIBDIR}/sbin \
            --sysconfdir=/etc/csync2 \
            --localstatedir=/var/lib/csync2 \
            --docdir=${CSYNC2_LIBDIR}/share/doc/csync2 \
            --enable-mysql \
            --enable-postgres \
            --enable-sqlite3

# Compile the source
make -j$(nproc)

# Install csync2 to temporary directory
rm -rf /tmp/installdir
mkdir -p /tmp/installdir
make install DESTDIR=/tmp/installdir

# Create RPM using fpm
echo "* $(date +"%a %b %d %Y") George Liu <centminmod.com> ${CSYNC2_VER}" > "csync2-${CSYNC2_VER}-changelog"
echo "- csync2 ${CSYNC2_VER} custom build" >> "csync2-${CSYNC2_VER}-changelog"
echo
cat "csync2-${CSYNC2_VER}-changelog"
echo

fpm -s dir -t rpm \
-n csync2-custom \
-v ${CSYNC2_VER} \
--rpm-compression xz \
--rpm-changelog "csync2-${CSYNC2_VER}-changelog" \
--rpm-summary "csync2 ${CSYNC2_VER} custom build" \
--rpm-dist "$DISTTAG" \
--description "csync2 ${CSYNC2_VER} custom build for Centminmod" \
--url "https://centminmod.com" \
--prefix /usr \
--rpm-autoreqprov \
--rpm-rpmbuild-define "_build_id_links none" \
--verbose \
-p "/workspace" \
-C /tmp/installdir

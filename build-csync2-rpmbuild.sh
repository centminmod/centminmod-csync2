#!/bin/bash

set -e

# Set variables
CSYNC2_VER=2.0

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
dnf groupinstall 'Development Tools' -y
dnf install --allowerasing -y \
  libpq-devel \
  wget \
  inotify-tools \
  nano \
  jq \
  bc \
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
  mysql-devel \
  texlive \
  texlive-latex

# Download and extract the csync2 source
wget "https://github.com/LINBIT/csync2/archive/refs/tags/csync2-${CSYNC2_VER}.tar.gz" -O "csync2-${CSYNC2_VER}.tar.gz"
tar xzf "csync2-${CSYNC2_VER}.tar.gz"

# Rename the extracted directory to match the spec file's expectation
mv csync2-csync2-${CSYNC2_VER} csync2-${CSYNC2_VER}
cd "csync2-${CSYNC2_VER}"

# Prepare for building the RPM
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp csync2.spec ~/rpmbuild/SPECS/
cp "../csync2-${CSYNC2_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Modify the %setup line in the spec file to match the extracted directory
sed -i "s/^%setup.*/%setup -n csync2-csync2-${CSYNC2_VER}/" ~/rpmbuild/SPECS/csync2.spec
sed -i '/^%build/a export CPPFLAGS="-I/usr/include"' ~/rpmbuild/SPECS/csync2.spec
sed -i '/^export CFLAGS=/i export RPM_OPT_FLAGS="$RPM_OPT_FLAGS -Wno-format-truncation -Wno-misleading-indentation -Wno-mismatched-dealloc"' ~/rpmbuild/SPECS/csync2.spec

# Modify the %prep section of the spec file to add sed commands for csync2_paper references
sed -i "/^%prep/a \
%setup -q -n csync2-csync2-${CSYNC2_VER}\n\
# Apply sed to remove csync2_paper references\n\
sed -i \"/doc\\/csync2_paper\\.tex/d\" Makefile.am\n\
sed -i \"/MANPDF/d\" Makefile.am\n\
sed -i \"/MANAUX/d\" Makefile.am\n\
sed -i \"/^if HAVE_PDFLATEX/,/^endif/d\" Makefile.am\n\
autoreconf --install\n\
# Dump Makefile for inspection\n\
echo === Begin Makefile ===\n\
cat ~/rpmbuild/BUILD/csync2-csync2-${CSYNC2_VER}/Makefile\n\
echo === End Makefile ===" ~/rpmbuild/SPECS/csync2.spec

# Modify the Makefile in the %prep section of the spec file
sed -i '/csync2_paper\.pdf/d' ~/rpmbuild/SPECS/csync2.spec

# Use sed to replace incorrect package names in the spec file
sed -i 's/libgnutls-devel/gnutls-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3-devel/sqlite-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3/sqlite/g' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires:.*sqlite/a Requires:       sqlite-libs' ~/rpmbuild/SPECS/csync2.spec

# Modify the %configure line to disable SQLite 2 and enable SQLite 3
sed -i 's/%configure .*/%configure --enable-mysql --enable-postgres --disable-sqlite --enable-sqlite3/' ~/rpmbuild/SPECS/csync2.spec

# create /etc/csync2
sed -i '/^%install/a \
mkdir -p %{buildroot}%{_sysconfdir}/csync2' ~/rpmbuild/SPECS/csync2.spec

# Regenerate the Makefile after modifying Makefile.am
autoreconf --install

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
cp ~/rpmbuild/RPMS/x86_64/*.rpm /workspace/rpms/ || echo "No RPM files found in ~/rpmbuild/RPMS/x86_64/"
cp ~/rpmbuild/SRPMS/*.rpm /workspace/rpms/ || echo "No SRPM files found in ~/rpmbuild/SRPMS/"

# Verify the copied files
ls -lah /workspace/rpms/

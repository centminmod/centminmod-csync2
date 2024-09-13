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

# Modify the %setup line to match the correct directory name (csync2-master)
sed -i 's/^%setup.*/%setup -n csync2-master/' ~/rpmbuild/SPECS/csync2.spec
sed -i '/^export CFLAGS=/i export RPM_OPT_FLAGS="$RPM_OPT_FLAGS -Wno-format-truncation -Wno-misleading-indentation -Wno-mismatched-dealloc"' ~/rpmbuild/SPECS/csync2.spec

# Use sed to replace incorrect package names in the spec file
sed -i 's/libgnutls-devel/gnutls-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3-devel/sqlite-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3/sqlite/g' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires:.*sqlite/a Requires:       sqlite-libs' ~/rpmbuild/SPECS/csync2.spec

# Modify the spec file to ensure the documentation directory exists
sed -i '/%install/a \
mkdir -p %{buildroot}%{_docdir}/csync2' ~/rpmbuild/SPECS/csync2.spec

# Modify the spec file to remove references to the missing files
sed -i '/ChangeLog/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/README/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/AUTHORS/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/xinetd.d\/csync2/d' ~/rpmbuild/SPECS/csync2.spec

# Add csync2-quickstart.adoc to %files section
sed -i '/%doc %{_docdir}\/csync2\/csync2.adoc/a %doc %{_docdir}/csync2/csync2-quickstart.adoc' ~/rpmbuild/SPECS/csync2.spec

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

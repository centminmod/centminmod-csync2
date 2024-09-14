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
  libpq-devel \
  wget \
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
sed -i "s/^Version:.*/Version: ${CSYNC2_VER}/" ~/rpmbuild/SPECS/csync2.spec

# Modify the Release field (optional)
sed -i 's/^Release:.*/Release: 1%{?dist}/' ~/rpmbuild/SPECS/csync2.spec

# Modify the Source0 line to point to the correct tar.gz
sed -i 's/^Source0:.*/Source0: %{name}-%{version}.tar.gz/' ~/rpmbuild/SPECS/csync2.spec

cp "../csync2-${CSYNC2_VER}.tar.gz" ~/rpmbuild/SOURCES/

# Modify the %setup line to match the correct directory name (csync2-master)
sed -i 's/^%setup.*/%setup -n csync2-master/' ~/rpmbuild/SPECS/csync2.spec
sed -i '/^%build/a export CPPFLAGS="-I/usr/include"' ~/rpmbuild/SPECS/csync2.spec
sed -i '/^export CFLAGS=/i export RPM_OPT_FLAGS="$RPM_OPT_FLAGS -Wno-format-truncation -Wno-misleading-indentation"' ~/rpmbuild/SPECS/csync2.spec

# Use sed to replace incorrect package names in the spec file
sed -i 's/libgnutls-devel/gnutls-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3-devel/sqlite-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3/sqlite/g' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires:.*sqlite/a Requires:       sqlite-libs' ~/rpmbuild/SPECS/csync2.spec

# Modify the spec file to remove references to the missing files
sed -i '/xinetd.d\/csync2/d' ~/rpmbuild/SPECS/csync2.spec

# Add csync2-quickstart.adoc to %files section
sed -i '/%doc %{_docdir}\/csync2\/csync2.adoc/a %doc %{_docdir}/csync2/csync2-quickstart.adoc' ~/rpmbuild/SPECS/csync2.spec

# Modify the %configure line to disable SQLite 2 and enable SQLite 3
sed -i 's|%configure .*|%configure --enable-systemd --enable-mysql --enable-postgres --disable-sqlite --enable-sqlite3 \\|' ~/rpmbuild/SPECS/csync2.spec

# Ensure documentation files are installed
sed -i '/%install/a \
install -m 644 AUTHORS %{buildroot}%{_docdir}/csync2/AUTHORS\n\
install -m 644 AUTHORS.adoc %{buildroot}%{_docdir}/csync2/AUTHORS.adoc\n\
install -m 644 README %{buildroot}%{_docdir}/csync2/README\n\
install -m 644 README.adoc %{buildroot}%{_docdir}/csync2/README.adoc' ~/rpmbuild/SPECS/csync2.spec

# Add the csync2.socket and csync2@.service systemd service management
sed -i '/%install/a \
install -D -m 644 csync2.socket %{buildroot}%{_unitdir}/csync2.socket\n\
install -D -m 644 csync2@.service %{buildroot}%{_unitdir}/csync2@.service' ~/rpmbuild/SPECS/csync2.spec

# Add command to install csync2.cfg
sed -i '/%install/a \
install -D -m 644 csync2.cfg %{buildroot}%{_sysconfdir}/csync2/csync2.cfg' ~/rpmbuild/SPECS/csync2.spec

# create /etc/csync2
sed -i '/^%install/a \
mkdir -p %{buildroot}%{_sysconfdir}/csync2' ~/rpmbuild/SPECS/csync2.spec

# Modify the spec file to ensure the documentation directory exists
sed -i '/%install/a \
mkdir -p %{buildroot}%{_docdir}/csync2' ~/rpmbuild/SPECS/csync2.spec

# Ensure all necessary directories are created
sed -i '/%install/a mkdir -p %{buildroot}%{_localstatedir}/lib/csync2' ~/rpmbuild/SPECS/csync2.spec

# Add a wildcard for any other documentation files
sed -i '/%files/a \
%doc %{_docdir}/csync2/*' ~/rpmbuild/SPECS/csync2.spec

# Ensure the socket and service files are included in the %files section
sed -i '/%files/a \
%{_unitdir}/csync2.socket\n\
%{_unitdir}/csync2@.service' ~/rpmbuild/SPECS/csync2.spec

# Add documentation files to the %files section
sed -i '/%files/a \
%doc %{_docdir}/csync2/AUTHORS.adoc\n\
%doc %{_docdir}/csync2/COPYING\n\
%doc %{_docdir}/csync2/ChangeLog\n\
%doc %{_docdir}/csync2/README.adoc\n\
%doc %{_docdir}/csync2/AUTHORS\n\
%doc %{_docdir}/csync2/README' ~/rpmbuild/SPECS/csync2.spec

# Replace %makeinstall with %make_install (modernize)
sed -i 's/%makeinstall/%make_install/' ~/rpmbuild/SPECS/csync2.spec

# Update the %files section to correctly reference csync2.cfg
sed -i 's|%config(noreplace) %{_sysconfdir}/csync2.cfg|%config(noreplace) %{_sysconfdir}/csync2/csync2.cfg|' ~/rpmbuild/SPECS/csync2.spec

# Update the %post section
sed -i '/%post/,/^$/c \
%post\n\
systemctl daemon-reload >/dev/null 2>\&1 || :\n\
systemctl preset csync2.socket >/dev/null 2>\&1 || :\n\
systemctl preset csync2@.service >/dev/null 2>\&1 || :\n\
if ! grep -q "^csync2" %{_sysconfdir}/services ; then\n\
    echo "csync2          30865/tcp" >>%{_sysconfdir}/services\n\
fi' ~/rpmbuild/SPECS/csync2.spec

# Update the %preun section
sed -i '/%preun/,/^$/c \
%preun\n\
systemctl --no-reload disable csync2.socket >/dev/null 2>\&1 || :\n\
systemctl stop csync2.socket >/dev/null 2>\&1 || :\n\
systemctl --no-reload disable csync2@.service >/dev/null 2>\&1 || :\n\
systemctl stop csync2@.service >/dev/null 2>\&1 || :' ~/rpmbuild/SPECS/csync2.spec

# Update the %postun section
sed -i '/%postun/,/^$/c \
%postun\n\
systemctl daemon-reload >/dev/null 2>\&1 || :' ~/rpmbuild/SPECS/csync2.spec

# Update BuildRequires for systemd
sed -i 's/BuildRequires:  systemd/BuildRequires:  systemd-rpm-macros/' ~/rpmbuild/SPECS/csync2.spec

# Remove existing systemd requirements
sed -i '/Requires\(post\): systemd/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires\(preun\): systemd/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires\(postun\): systemd/d' ~/rpmbuild/SPECS/csync2.spec

echo
cat ~/rpmbuild/SPECS/csync2.spec
echo

# Add systemd requirements once
sed -i '/Requires:       sqlite-libs/a Requires(post): systemd\nRequires(preun): systemd\nRequires(postun): systemd' ~/rpmbuild/SPECS/csync2.spec

# Check if %pre section exists and remove it if found
if grep -q '^%pre$' ~/rpmbuild/SPECS/csync2.spec; then
    sed -i '/^%pre$/,/^$/d' ~/rpmbuild/SPECS/csync2.spec
    sed -i '/^%pre$/d' ~/rpmbuild/SPECS/csync2.spec
    echo "Removed %pre section from spec file"
else
    echo "No %pre section found in spec file"
fi

# Add new changelog entry
sed -i '/^%changelog/a \* '"$(date +"%a %b %d %Y")"' George Liu <centminmod.com> - 2.1-1\n- Update for EL8/EL9 OSes\n' ~/rpmbuild/SPECS/csync2.spec

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
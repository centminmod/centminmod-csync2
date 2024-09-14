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
sed -i '/^%build/a export CPPFLAGS="-I/usr/include"' ~/rpmbuild/SPECS/csync2.spec
sed -i '/^export CFLAGS=/i export RPM_OPT_FLAGS="$RPM_OPT_FLAGS -Wno-format-truncation -Wno-misleading-indentation -Wno-mismatched-dealloc"' ~/rpmbuild/SPECS/csync2.spec

# Use sed to replace incorrect package names in the spec file
sed -i 's/libgnutls-devel/gnutls-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3-devel/sqlite-devel/g' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/sqlite3/sqlite/g' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires:.*sqlite/a Requires:       sqlite-libs' ~/rpmbuild/SPECS/csync2.spec

# Modify the spec file to remove references to the missing files
# sed -i '/ChangeLog/d' ~/rpmbuild/SPECS/csync2.spec
# sed -i '/README/d' ~/rpmbuild/SPECS/csync2.spec
# sed -i '/AUTHORS/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/xinetd.d\/csync2/d' ~/rpmbuild/SPECS/csync2.spec

# Add csync2-quickstart.adoc to %files section
sed -i '/%doc %{_docdir}\/csync2\/csync2.adoc/a %doc %{_docdir}/csync2/csync2-quickstart.adoc' ~/rpmbuild/SPECS/csync2.spec

# Modify the %configure line to disable SQLite 2 and enable SQLite 3
sed -i 's|%configure .*|%configure --enable-mysql --enable-postgres --disable-sqlite --enable-sqlite3 \\|' ~/rpmbuild/SPECS/csync2.spec

# Ensure documentation files are installed
sed -i '/%install/a \
install -m 644 AUTHORS %{buildroot}%{_docdir}/csync2/AUTHORS\n\
install -m 644 AUTHORS.adoc %{buildroot}%{_docdir}/csync2/AUTHORS.adoc\n\
install -m 644 README %{buildroot}%{_docdir}/csync2/README\n\
install -m 644 README.adoc %{buildroot}%{_docdir}/csync2/README.adoc' ~/rpmbuild/SPECS/csync2.spec

# Add the csync2.socket systemd service management
sed -i '/%install/a \
install -D -m 644 csync2.socket %{buildroot}%{_unitdir}/csync2.socket' ~/rpmbuild/SPECS/csync2.spec

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

# Ensure the service management in pre/post install scripts if not already present
if ! grep -q "%pre" ~/rpmbuild/SPECS/csync2.spec; then
    sed -i '/^%install/i \
%pre \
%service_add_pre csync2.socket' ~/rpmbuild/SPECS/csync2.spec
fi

if ! grep -q "%post" ~/rpmbuild/SPECS/csync2.spec; then
    sed -i '/^%install/i \
%post \
%service_add_post csync2.socket' ~/rpmbuild/SPECS/csync2.spec
fi

if ! grep -q "%preun" ~/rpmbuild/SPECS/csync2.spec; then
    sed -i '/^%install/i \
%preun \
%service_del_preun csync2.socket' ~/rpmbuild/SPECS/csync2.spec
fi

if ! grep -q "%postun" ~/rpmbuild/SPECS/csync2.spec; then
    sed -i '/^%install/i \
%postun \
%service_del_postun csync2.socket' ~/rpmbuild/SPECS/csync2.spec
fi

# Add a wildcard for any other documentation files
sed -i '/%files/a \
%doc %{_docdir}/csync2/*' ~/rpmbuild/SPECS/csync2.spec

# Ensure the socket file is included in the %files section
sed -i '/%files/a \
%{_unitdir}/csync2.socket' ~/rpmbuild/SPECS/csync2.spec

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

# Replace SUSE-specific service management with RHEL-compatible commands
sed -i 's/%service_add_pre csync2.socket/systemctl preset csync2.socket >\/dev\/null 2>\&1 || :/' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/%service_add_post csync2.socket/systemctl daemon-reload >\/dev\/null 2>\&1 || :/' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/%service_del_preun csync2.socket/systemctl --no-reload disable csync2.socket >\/dev\/null 2>\&1 || :\nsystemctl stop csync2.socket >\/dev\/null 2>\&1 || :/' ~/rpmbuild/SPECS/csync2.spec
sed -i 's/%service_del_postun csync2.socket/systemctl daemon-reload >\/dev\/null 2>\&1 || :/' ~/rpmbuild/SPECS/csync2.spec

# Update BuildRequires for systemd
sed -i 's/BuildRequires:  systemd/BuildRequires:  systemd-rpm-macros/' ~/rpmbuild/SPECS/csync2.spec

# Remove existing systemd requirements
sed -i '/Requires\(post\): systemd/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires\(preun\): systemd/d' ~/rpmbuild/SPECS/csync2.spec
sed -i '/Requires\(postun\): systemd/d' ~/rpmbuild/SPECS/csync2.spec

# Add systemd requirements once
sed -i '/^Requires:/a Requires(post): systemd\nRequires(preun): systemd\nRequires(postun): systemd' ~/rpmbuild/SPECS/csync2.spec

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

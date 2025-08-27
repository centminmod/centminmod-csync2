#!/bin/bash
set -e

HOSTNAME=$1
OTHER_HOST=$2
OTHER_IP=$3
SKIP_INSTALL=$4

echo "Setting up csync2 on ${HOSTNAME}..."

# Only install if not skipped
if [ "$SKIP_INSTALL" != "skip_install" ]; then
  # Determine DISTTAG based on OS release
  if grep -q "release 8" /etc/redhat-release; then
      DISTTAG='el8'
      CRB_REPO="powertools"
  elif grep -q "release 9" /etc/redhat-release; then
      DISTTAG='el9'
      CRB_REPO="crb"
  fi
  
  # Install dependencies
  dnf clean all
  dnf install -y epel-release --quiet
  dnf config-manager --set-enabled "${CRB_REPO}"
  
  # Install all required dependencies for csync2
  dnf install -y \
      sqlite \
      sqlite-devel \
      librsync \
      librsync-devel \
      inotify-tools \
      iputils \
      iproute \
      hostname \
      gnutls \
      libgcrypt \
      openssl \
      net-tools \
      nmap-ncat --quiet
  
  # Find and install csync2 RPM
  RPM_FILE=$(ls /rpms/csync2-2.1.1-*.x86_64.rpm 2>/dev/null | grep -v debuginfo | head -n1)
  if [ -z "$RPM_FILE" ]; then
    echo "Error: csync2 RPM not found in /rpms/"
    ls -la /rpms/
    exit 1
  fi
  echo "Installing: $RPM_FILE"
  rpm -ivh "$RPM_FILE" || rpm -Uvh "$RPM_FILE"
fi

# Add hosts to /etc/hosts (avoid duplicates)
grep -q "10.10.10.2 host1" /etc/hosts || echo "10.10.10.2 host1" >> /etc/hosts
grep -q "10.10.10.3 host2" /etc/hosts || echo "10.10.10.3 host2" >> /etc/hosts

# Create test directory
mkdir -p /home/csync2-testdir

# Generate csync2 key (only on host1 if not skipped)
if [ "$HOSTNAME" = "host1" ] && [ "$SKIP_INSTALL" != "skip_install" ]; then
  csync2 -k /etc/csync2/csync2.key
  chmod 600 /etc/csync2/csync2.key
fi

# Generate SSL certificate and key for encrypted connections
echo "Generating SSL certificate for ${HOSTNAME}..."
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/C=US/ST=State/L=City/O=CSyncTest/CN=${HOSTNAME}" \
  -keyout /etc/csync2/csync2_ssl_key.pem \
  -out /etc/csync2/csync2_ssl_cert.pem
chmod 600 /etc/csync2/csync2_ssl_key.pem
chmod 644 /etc/csync2/csync2_ssl_cert.pem

# Create csync2 config
cat > /etc/csync2/csync2.cfg <<'CFGEOF'
group testgroup {
    host host1;
    host host2;
    
    key /etc/csync2/csync2.key;
    
    include /home/csync2-testdir;
    
    auto younger;
    
    # batch_delete_limit 20000;
}
CFGEOF

# Start csync2 socket or daemon
if command -v systemctl &> /dev/null && systemctl list-units &> /dev/null; then
  echo "Using systemd to start csync2..."
  systemctl daemon-reload
  systemctl start csync2.socket
  systemctl enable csync2.socket
else
  echo "Systemd not available, using inotify_csync.sh approach..."
  
  # Setup inotify_csync.sh
  echo "=== Setting up inotify_csync.sh ==="
  
  # Check multiple possible locations for inotify_csync.sh
  INOTIFY_SCRIPT=""
  for location in \
    "/usr/share/doc/csync2/inotify_csync.sh" \
    "/usr/share/doc/csync2-2.1.1/inotify_csync.sh" \
    $(ls /usr/share/doc/csync2*/inotify_csync.sh 2>/dev/null | head -1)
  do
    if [ -f "$location" ]; then
      INOTIFY_SCRIPT="$location"
      echo "✓ Found at $location"
      break
    fi
  done
  
  # Use found script or create fallback
  if [ -n "$INOTIFY_SCRIPT" ]; then
    echo "Copying inotify_csync.sh from RPM installation..."
    cp "$INOTIFY_SCRIPT" /usr/local/bin/inotify_csync
    chmod +x /usr/local/bin/inotify_csync
    echo "✓ Successfully installed inotify_csync.sh"
  else
    echo "⚠ inotify_csync.sh not found, creating minimal daemon wrapper..."
    cat > /usr/local/bin/inotify_csync << 'WRAPPER_EOF'
#!/bin/bash
# Minimal csync2 daemon wrapper for testing
HOSTNAME="${2:-$(hostname)}"
echo "Starting csync2 daemon for ${HOSTNAME}..."
exec /usr/sbin/csync2 -ii -vvv -N ${HOSTNAME}
WRAPPER_EOF
    chmod +x /usr/local/bin/inotify_csync
    echo "✓ Created minimal fallback wrapper"
  fi
  
  # Create required directories
  mkdir -p /home/csync2-inotify/tmp
  chmod 755 /home/csync2-inotify
  
  # Create systemd service
  cat > /etc/systemd/system/inotify_csync.service << 'SERVICE_EOF'
[Unit]
Description=Inotify Csync2 Sync Service
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash -c 'pgrep -f csync2 && killall csync2 || true'
ExecStart=/usr/local/bin/inotify_csync -N %H
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/home/csync2-inotify
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF
  
  # Start service
  systemctl daemon-reload
  systemctl enable inotify_csync.service
  systemctl start inotify_csync.service
  
  # Wait and verify
  sleep 3
  systemctl status inotify_csync.service --no-pager -l || true
  journalctl -u inotify_csync.service --no-pager | tail -25
fi

echo "Setup complete on ${HOSTNAME}"
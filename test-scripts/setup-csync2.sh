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

# Start csync2 daemon - DIRECT MODE
echo "Using direct daemon mode (avoiding systemd/D-Bus issues)..."

# Pre-daemon startup debug info
echo "=== Pre-daemon startup debug info ==="
echo "Hostname: ${HOSTNAME}"
echo "csync2 version:"
/usr/sbin/csync2 -v || true
echo ""

# Validate config and SSL files
echo "=== Configuration validation ==="
if [ -f /etc/csync2/csync2.cfg ]; then
  echo "✓ Config file exists"
  chmod 644 /etc/csync2/csync2.cfg
else
  echo "✗ Config file missing!"
  ls -la /etc/csync2/
fi

if [ -f /etc/csync2/csync2_ssl_cert.pem ] && [ -f /etc/csync2/csync2_ssl_key.pem ]; then
  echo "✓ SSL certificates exist"
else
  echo "✗ SSL certificates missing!"
  ls -la /etc/csync2/*.pem 2>/dev/null || true
fi

if [ -f /etc/csync2/csync2.key ]; then
  echo "✓ Key file exists"
else
  echo "✗ Key file missing!"
fi
echo ""

# Create required directories
mkdir -p /home/csync2-inotify/tmp
chmod 755 /home/csync2-inotify

# Kill any existing processes (with completely safe error handling)
echo "Cleaning up any existing csync2 processes..."
{
  # Check for processes first
  EXISTING_PROCESSES=$(pgrep -f csync2 2>/dev/null | wc -l)
  if [ "$EXISTING_PROCESSES" -gt 0 ]; then
    echo "Found $EXISTING_PROCESSES existing csync2 processes, terminating..."
    
    # Get process IDs
    PIDS=$(pgrep -f csync2 2>/dev/null || echo "")
    if [ -n "$PIDS" ]; then
      echo "Terminating PIDs: $PIDS"
      for pid in $PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
          kill "$pid" 2>/dev/null || echo "Could not terminate PID $pid"
        fi
      done
      
      # Wait a moment
      sleep 2
      
      # Check if any are still running and force kill
      REMAINING_PIDS=$(pgrep -f csync2 2>/dev/null || echo "")
      if [ -n "$REMAINING_PIDS" ]; then
        echo "Force killing remaining PIDs: $REMAINING_PIDS"
        for pid in $REMAINING_PIDS; do
          if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || echo "Could not force kill PID $pid"
          fi
        done
        sleep 1
      fi
    fi
    echo "Process cleanup completed"
  else
    echo "No existing csync2 processes found"
  fi
} 2>/dev/null || {
  echo "Process cleanup had some issues, but continuing..."
}

echo "Configuration file contents:"
cat /etc/csync2/csync2.cfg
echo ""

# Start csync2 daemon directly without any systemd dependency
echo "Starting csync2 daemon directly..."
nohup /usr/sbin/csync2 -ii -vvv -N "${HOSTNAME}" > /tmp/csync2_daemon.log 2>&1 &
DAEMON_PID=$!
echo $DAEMON_PID > /tmp/csync2_daemon.pid
echo "Started csync2 daemon with PID $DAEMON_PID"

# Wait and verify startup
sleep 5

echo "=== Post-startup verification ==="
if kill -0 $DAEMON_PID 2>/dev/null; then
  echo "✓ Daemon running (PID: $DAEMON_PID)"
else
  echo "✗ Daemon not running"
  echo "Daemon log:"
  cat /tmp/csync2_daemon.log || echo "No log file found"
fi

echo "Process check:"
ps aux | grep csync2 | grep -v grep || echo "No csync2 processes found"

echo "Port check:"
if netstat -tln | grep -q 30865; then
  echo "✓ Port 30865 is listening"
  netstat -tlnp | grep 30865 || true
else
  echo "✗ Port 30865 not listening"
  echo "All listening ports:"
  netstat -tln
  echo "Daemon log:"
  cat /tmp/csync2_daemon.log || echo "No log file"
fi

echo "Connection test to localhost:"
nc -zv localhost 30865 2>&1 || echo "Cannot connect to port 30865"

echo "Setup complete on ${HOSTNAME}"
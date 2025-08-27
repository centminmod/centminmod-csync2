#!/bin/bash
set -e

echo "=== Starting csync2 sync tests ==="

# Pre-sync debug information
echo "=== Pre-sync debug information ==="
echo "Current hostname: $(hostname)"
echo "Database files:"
ls -la /var/lib/csync2/*.db* 2>/dev/null || echo "No database files found"
echo "Configuration check:"
/usr/sbin/csync2 -T || echo "Configuration test failed"

# Test 1: Basic file sync
echo "Test 1: Creating test file on host1..."
echo "Hello from host1" > /home/csync2-testdir/test1.txt
echo "Running sync with maximum verbosity..."
/usr/sbin/csync2 -xvvvr /home/csync2-testdir || true
sleep 2

# Test 2: Multiple files
echo "Test 2: Creating multiple files..."
for i in {1..10}; do
  echo "File $i content" > /home/csync2-testdir/file$i.txt
done
echo "Running sync with maximum verbosity..."
/usr/sbin/csync2 -xvvvr /home/csync2-testdir || true
sleep 2

# Test 3: File modification
echo "Test 3: Modifying file..."
echo "Modified content" >> /home/csync2-testdir/test1.txt
echo "Running sync with maximum verbosity..."
/usr/sbin/csync2 -xvvvr /home/csync2-testdir || true
sleep 2

# Test 4: File deletion
echo "Test 4: Deleting file..."
rm -f /home/csync2-testdir/file5.txt
echo "Running sync with maximum verbosity..."
/usr/sbin/csync2 -xvvvr /home/csync2-testdir || true
sleep 2

# Test 5: Batch delete limit test
echo "Test 5: Testing batch delete limit..."
for i in {1..100}; do
  echo "Batch test $i" > /home/csync2-testdir/batch$i.txt
done
echo "Running sync with maximum verbosity..."
/usr/sbin/csync2 -xvvvbr /home/csync2-testdir || true
sleep 3
echo "Deleting all batch files..."
rm -f /home/csync2-testdir/batch*.txt
echo "Running sync after batch delete..."
/usr/sbin/csync2 -xvvvbr /home/csync2-testdir || true
sleep 3

echo "=== Sync tests completed ==="

# Final debug information
echo "=== Post-sync debug information ==="
echo "Database dirty entries:"
/usr/sbin/csync2 -M || echo "No dirty entries or command failed"
echo "Database hint entries:"
/usr/sbin/csync2 -H || echo "No hint entries or command failed"
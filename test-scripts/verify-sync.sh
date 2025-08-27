#!/bin/bash
set -e

echo "=== Verifying sync on host2 ==="

# Check if test files exist
ERRORS=0

# Test 1 verification
if [ -f /home/csync2-testdir/test1.txt ]; then
  echo "✓ Test 1: test1.txt exists"
  content=$(cat /home/csync2-testdir/test1.txt)
  if [[ "$content" == *"Modified content"* ]]; then
    echo "✓ Test 3: File modification synced"
  else
    echo "✗ Test 3: File modification NOT synced"
    ((ERRORS++))
  fi
else
  echo "✗ Test 1: test1.txt missing"
  ((ERRORS++))
fi

# Test 2 verification
file_count=$(ls -1 /home/csync2-testdir/file*.txt 2>/dev/null | wc -l)
if [ "$file_count" -eq 9 ]; then
  echo "✓ Test 2 & 4: Correct number of files (9, file5.txt deleted)"
else
  echo "✗ Test 2 & 4: Expected 9 files, found $file_count"
  ((ERRORS++))
fi

# Test 5 verification
batch_count=$(ls -1 /home/csync2-testdir/batch*.txt 2>/dev/null | wc -l)
if [ "$batch_count" -eq 0 ]; then
  echo "✓ Test 5: Batch files deleted successfully"
else
  echo "✗ Test 5: Found $batch_count batch files, expected 0"
  ((ERRORS++))
fi

echo
echo "=== Verification Results ==="
if [ "$ERRORS" -eq 0 ]; then
  echo "SUCCESS: All tests passed!"
  exit 0
else
  echo "FAILURE: $ERRORS test(s) failed"
  ls -la /home/csync2-testdir/
  exit 1
fi
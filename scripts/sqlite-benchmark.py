#!/usr/bin/env python3

import sqlite3
import time
import os
import random
import string
import hashlib
import subprocess
import sys
import argparse

def get_sqlite_version(sqlite_path):
    try:
        result = subprocess.run([sqlite_path, "--version"], capture_output=True, text=True)
        return result.stdout.strip()
    except FileNotFoundError:
        return None

def random_string(length):
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))

def random_checksum():
    return hashlib.md5(random_string(100).encode()).hexdigest()

def create_connection(db_path):
    try:
        return sqlite3.connect(db_path)
    except sqlite3.Error as e:
        print(f"Error connecting to database: {e}")
        return None

def setup_csync2_schema(conn):
    try:
        cursor = conn.cursor()
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS file (
            filename TEXT PRIMARY KEY,
            checktxt TEXT,
            digest TEXT
        )''')
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS dirty (
            filename TEXT PRIMARY KEY,
            force INTEGER,
            myname TEXT,
            peername TEXT,
            operation TEXT
        )''')
        conn.commit()
    except sqlite3.Error as e:
        print(f"Error setting up schema: {e}")
        conn.rollback()

def run_benchmark(db_path, num_files=100000, batch_size=5000):
    conn = create_connection(db_path)
    if not conn:
        return None

    setup_csync2_schema(conn)
    cursor = conn.cursor()

    results = {}

    try:
        # Simulate adding new files in batches
        insert_start = time.time()
        for i in range(0, num_files, batch_size):
            batch = [(f"/var/lib/csync2/test_file_{j}.txt", random_string(20), random_checksum())
                     for j in range(i, min(i + batch_size, num_files))]
            cursor.executemany("INSERT OR REPLACE INTO file (filename, checktxt, digest) VALUES (?, ?, ?)", batch)
            conn.commit()
        insert_end = time.time()
        results["insert_files"] = insert_end - insert_start

        # Simulate checking for changes
        check_changes_start = time.time()
        cursor.execute("SELECT filename, checktxt FROM file ORDER BY RANDOM() LIMIT ?", (num_files // 10,))
        files = cursor.fetchall()
        dirty_files = []
        for filename, checktxt in files:
            if random.random() < 0.1:  # 10% chance of file being "changed"
                new_checktxt = random_string(20)
                if new_checktxt != checktxt:
                    dirty_files.append((filename, 0, 'localhost', 'peer1', 'UPDATE'))
        cursor.executemany("INSERT OR REPLACE INTO dirty (filename, force, myname, peername, operation) VALUES (?, ?, ?, ?, ?)", dirty_files)
        conn.commit()
        check_changes_end = time.time()
        results["check_changes"] = check_changes_end - check_changes_start

        # Simulate synchronization process
        sync_start = time.time()
        cursor.execute("SELECT filename FROM dirty LIMIT ?", (num_files // 100,))
        dirty_files = cursor.fetchall()
        for batch in [dirty_files[i:i + batch_size] for i in range(0, len(dirty_files), batch_size)]:
            updates = [(random_checksum(), filename[0]) for filename in batch]
            cursor.executemany("UPDATE file SET digest = ? WHERE filename = ?", updates)
            cursor.executemany("DELETE FROM dirty WHERE filename = ?", batch)
            conn.commit()
        sync_end = time.time()
        results["sync_process"] = sync_end - sync_start

        # Complex query: Find files that are in dirty state but not in file table
        complex_query_start = time.time()
        cursor.execute("""
            SELECT d.filename
            FROM dirty d
            LEFT JOIN file f ON d.filename = f.filename
            WHERE f.filename IS NULL
        """)
        orphaned_dirty = cursor.fetchall()
        complex_query_end = time.time()
        results["complex_query"] = complex_query_end - complex_query_start

        # Simulate file deletions
        delete_start = time.time()
        cursor.execute("SELECT filename FROM file ORDER BY RANDOM() LIMIT ?", (num_files // 1000,))
        files_to_delete = cursor.fetchall()
        cursor.executemany("DELETE FROM file WHERE filename = ?", files_to_delete)
        cursor.executemany("INSERT INTO dirty (filename, force, myname, peername, operation) VALUES (?, 0, 'localhost', 'peer1', 'DELETE')", files_to_delete)
        conn.commit()
        delete_end = time.time()
        results["file_deletions"] = delete_end - delete_start

        # Index creation (if not exists)
        index_start = time.time()
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_file_filename ON file (filename)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_dirty_filename ON dirty (filename)")
        conn.commit()
        index_end = time.time()
        results["index_creation"] = index_end - index_start

    except sqlite3.Error as e:
        print(f"Error during benchmark: {e}")
        conn.rollback()
        return None
    finally:
        conn.close()

    return results

def get_database_stats(db_path):
    conn = create_connection(db_path)
    if not conn:
        return None

    stats = {}
    try:
        cursor = conn.cursor()
        
        # Get table sizes
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = cursor.fetchall()
        for table in tables:
            cursor.execute(f"SELECT COUNT(*) FROM {table[0]}")
            stats[f"{table[0]}_count"] = cursor.fetchone()[0]

        # Get index information
        cursor.execute("SELECT name FROM sqlite_master WHERE type='index'")
        indexes = cursor.fetchall()
        stats["index_count"] = len(indexes)

        # Get database size
        stats["db_size_bytes"] = os.path.getsize(db_path)

        # Get page count and page size
        cursor.execute("PRAGMA page_count")
        stats["page_count"] = cursor.fetchone()[0]
        cursor.execute("PRAGMA page_size")
        stats["page_size"] = cursor.fetchone()[0]

        # Get free pages
        cursor.execute("PRAGMA freelist_count")
        stats["free_pages"] = cursor.fetchone()[0]

    except sqlite3.Error as e:
        print(f"Error getting database stats: {e}")
        return None
    finally:
        conn.close()

    return stats

def print_database_stats(stats):
    if not stats:
        print("Unable to retrieve database statistics.")
        return

    print("\nDatabase Statistics:")
    print(f"File table count: {stats.get('file_count', 'N/A')}")
    print(f"Dirty table count: {stats.get('dirty_count', 'N/A')}")
    print(f"Number of indexes: {stats.get('index_count', 'N/A')}")
    print(f"Database size: {stats.get('db_size_bytes', 'N/A')} bytes")
    print(f"Page count: {stats.get('page_count', 'N/A')}")
    print(f"Page size: {stats.get('page_size', 'N/A')} bytes")
    print(f"Free pages: {stats.get('free_pages', 'N/A')}")

def main():
    parser = argparse.ArgumentParser(description='Benchmark SQLite for csync2-like operations')
    parser.add_argument('--custom-sqlite-path', default='/opt/sqlite-custom',
                        help='Path to custom SQLite installation (default: /opt/sqlite-custom)')
    parser.add_argument('--num-files', type=int, default=1000000,
                        help='Number of files to simulate (default: 1,000,000)')
    args = parser.parse_args()

    home_dir = os.path.expanduser("~")
    system_sqlite_path = os.path.join(home_dir, "csync2_system_sqlite_benchmark.db")
    custom_sqlite_path = os.path.join(home_dir, "csync2_custom_sqlite_benchmark.db")

    system_sqlite_version = get_sqlite_version("sqlite3")
    if not system_sqlite_version:
        print("Error: System SQLite not found. Please ensure SQLite is installed.")
        sys.exit(1)

    print(f"Benchmarking System SQLite ({system_sqlite_version}) for csync2-like operations:")
    system_results = run_benchmark(system_sqlite_path, num_files=args.num_files)
    if system_results:
        for operation, duration in system_results.items():
            print(f"{operation}: {duration:.4f} seconds")
        print_database_stats(get_database_stats(system_sqlite_path))
    else:
        print("System SQLite benchmark failed.")

    custom_sqlite_bin = os.path.join(args.custom_sqlite_path, "bin", "sqlite3")
    custom_sqlite_version = get_sqlite_version(custom_sqlite_bin)
    if custom_sqlite_version:
        print(f"\nBenchmarking Custom SQLite ({custom_sqlite_version}) for csync2-like operations:")
        os.environ["LD_LIBRARY_PATH"] = f"{args.custom_sqlite_path}/lib:$LD_LIBRARY_PATH"
        custom_results = run_benchmark(custom_sqlite_path, num_files=args.num_files)
        if custom_results:
            for operation, duration in custom_results.items():
                print(f"{operation}: {duration:.4f} seconds")
            print_database_stats(get_database_stats(custom_sqlite_path))

            print("\nPerformance Comparison (Custom vs System):")
            for operation in system_results.keys():
                diff = (system_results[operation] - custom_results[operation]) / system_results[operation] * 100
                print(f"{operation}: {diff:.2f}% {'improvement' if diff > 0 else 'slower'}")
        else:
            print("Custom SQLite benchmark failed.")
    else:
        print(f"\nCustom SQLite not found at {custom_sqlite_bin}. Skipping custom SQLite benchmark.")

if __name__ == "__main__":
    main()
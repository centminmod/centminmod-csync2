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
import urllib.parse

def get_sqlite_version(sqlite_path):
    try:
        result = subprocess.run([sqlite_path, "--version"], capture_output=True, text=True)
        return result.stdout.strip()
    except FileNotFoundError:
        return None

def random_string(length):
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))

def random_checktxt():
    mtime = int(time.time())
    mode = random.randint(30000, 40000)
    uid = random.randint(1000, 2000)
    gid = random.randint(100, 200)
    size = random.randint(100, 10000)
    return f"v1:mtime={mtime}:mode={mode}:uid={uid}:gid={gid}:type=reg:size={size}"

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
            filename TEXT,
            checktxt TEXT,
            UNIQUE (filename) ON CONFLICT REPLACE
        )''')
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS dirty (
            filename TEXT,
            force INTEGER,
            myname TEXT,
            peername TEXT,
            UNIQUE (filename, peername) ON CONFLICT IGNORE
        )''')
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS hint (
            filename TEXT,
            recursive INTEGER,
            UNIQUE (filename, recursive) ON CONFLICT IGNORE
        )''')
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS action (
            filename TEXT,
            command TEXT,
            logfile TEXT,
            UNIQUE (filename, command) ON CONFLICT IGNORE
        )''')
        cursor.execute('''
        CREATE TABLE IF NOT EXISTS x509_cert (
            peername TEXT,
            certdata TEXT,
            UNIQUE (peername) ON CONFLICT IGNORE
        )''')
        conn.commit()
    except sqlite3.Error as e:
        print(f"Error setting up schema: {e}")
        conn.rollback()

def clear_database(conn):
    try:
        cursor = conn.cursor()
        cursor.execute("DELETE FROM file")
        cursor.execute("DELETE FROM dirty")
        cursor.execute("DELETE FROM hint")
        cursor.execute("DELETE FROM action")
        cursor.execute("DELETE FROM x509_cert")
        conn.commit()
    except sqlite3.Error as e:
        print(f"Error clearing database: {e}")
        conn.rollback()

def run_benchmark(db_path, num_files=100000, batch_size=1000, clear_existing=True):
    conn = create_connection(db_path)
    if not conn:
        return None

    setup_csync2_schema(conn)
    
    if clear_existing:
        clear_database(conn)

    cursor = conn.cursor()
    results = {}

    try:
        # Simulate adding new files
        insert_start = time.time()
        for i in range(0, num_files, batch_size):
            batch = [(urllib.parse.quote(f"/var/lib/csync2/test_file_{j}.txt"), random_checktxt())
                     for j in range(i, min(i + batch_size, num_files))]
            cursor.executemany("INSERT OR REPLACE INTO file (filename, checktxt) VALUES (?, ?)", batch)
            conn.commit()
        insert_end = time.time()
        results["insert_files"] = insert_end - insert_start

        # Simulate marking files as dirty
        dirty_start = time.time()
        cursor.execute("SELECT filename FROM file ORDER BY RANDOM() LIMIT ?", (num_files // 10,))
        files = cursor.fetchall()
        dirty_files = [(file[0], 0, 'localhost', 'peer1') for file in files]
        cursor.executemany("INSERT OR IGNORE INTO dirty (filename, force, myname, peername) VALUES (?, ?, ?, ?)", dirty_files)
        conn.commit()
        dirty_end = time.time()
        results["mark_dirty"] = dirty_end - dirty_start

        # Simulate updating files
        update_start = time.time()
        cursor.execute("SELECT filename FROM dirty LIMIT ?", (num_files // 100,))
        dirty_files = cursor.fetchall()
        for batch in [dirty_files[i:i + batch_size] for i in range(0, len(dirty_files), batch_size)]:
            updates = [(random_checktxt(), file[0]) for file in batch]
            cursor.executemany("UPDATE file SET checktxt = ? WHERE filename = ?", updates)
            cursor.executemany("DELETE FROM dirty WHERE filename = ?", batch)
            conn.commit()
        update_end = time.time()
        results["update_files"] = update_end - update_start

        # Simulate adding hints
        hint_start = time.time()
        hint_files = [(file[0], random.choice([0, 1])) for file in random.sample(files, num_files // 20)]
        cursor.executemany("INSERT OR IGNORE INTO hint (filename, recursive) VALUES (?, ?)", hint_files)
        conn.commit()
        hint_end = time.time()
        results["add_hints"] = hint_end - hint_start

        # Simulate scheduling actions
        action_start = time.time()
        action_files = [(file[0], random.choice(['CHECK', 'UPDATE', 'DELETE']), 'logfile.txt') for file in random.sample(files, num_files // 50)]
        cursor.executemany("INSERT OR IGNORE INTO action (filename, command, logfile) VALUES (?, ?, ?)", action_files)
        conn.commit()
        action_end = time.time()
        results["schedule_actions"] = action_end - action_start

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
    for table in ['file', 'dirty', 'hint', 'action', 'x509_cert']:
        print(f"{table.capitalize()} table count: {stats.get(f'{table}_count', 'N/A')}")
    print(f"Number of indexes: {stats.get('index_count', 'N/A')}")
    print(f"Database size: {stats.get('db_size_bytes', 'N/A')} bytes")
    print(f"Page count: {stats.get('page_count', 'N/A')}")
    print(f"Page size: {stats.get('page_size', 'N/A')} bytes")
    print(f"Free pages: {stats.get('free_pages', 'N/A')}")

def main():
    parser = argparse.ArgumentParser(description='Benchmark SQLite for csync2-like operations')
    parser.add_argument('--custom-sqlite-path', default='/opt/sqlite-custom',
                        help='Path to custom SQLite installation (default: /opt/sqlite-custom)')
    parser.add_argument('--num-files', type=int, default=100000,
                        help='Number of files to simulate (default: 100,000)')
    parser.add_argument('--new-db', action='store_true',
                        help='Create a new database for each run')
    parser.add_argument('--no-clear', action='store_true',
                        help='Do not clear existing data before running the benchmark')
    args = parser.parse_args()

    home_dir = os.path.expanduser("~")
    system_sqlite_path = os.path.join(home_dir, "csync2_system_sqlite_benchmark.db")
    custom_sqlite_path = os.path.join(home_dir, "csync2_custom_sqlite_benchmark.db")

    if args.new_db:
        timestamp = int(time.time())
        system_sqlite_path = os.path.join(home_dir, f"csync2_system_sqlite_benchmark_{timestamp}.db")
        custom_sqlite_path = os.path.join(home_dir, f"csync2_custom_sqlite_benchmark_{timestamp}.db")

    clear_existing = not args.no_clear

    system_sqlite_version = get_sqlite_version("sqlite3")
    if not system_sqlite_version:
        print("Error: System SQLite not found. Please ensure SQLite is installed.")
        sys.exit(1)

    print(f"Benchmarking System SQLite ({system_sqlite_version}) for csync2-like operations:")
    system_results = run_benchmark(system_sqlite_path, num_files=args.num_files, clear_existing=clear_existing)
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
        custom_results = run_benchmark(custom_sqlite_path, num_files=args.num_files, clear_existing=clear_existing)
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
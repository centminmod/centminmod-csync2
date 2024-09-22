#!/usr/bin/env python3

import os
import queue
import threading
import subprocess
import time
import signal
import logging
import argparse
import concurrent.futures
import pyinotify
import asyncio
import sys
import traceback

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Global variables
queue_file = "/home/csync2-inotify/tmp/inotify_queue_python.log"
csync_log_file = "/home/csync2-inotify/tmp/csync_server_python.log"
check_interval = 0.5
full_sync_interval = 3600
num_lines_until_reset = 200000
num_batched_changes_threshold = 15000
rsync_threshold = 5000
parallel_updates = 1
max_wait_time = 10  # seconds
last_full_sync = 0
queue_line_pos = 1
config_file = "/etc/csync2/csync2.cfg"
use_rsync = False

class ChangeEventHandler(pyinotify.ProcessEvent):
    def __init__(self, queue):
        self.queue = queue

    def process_default(self, event):
        logger.debug(f"Detected event: {event.maskname} on {event.pathname}")
        self.queue.put(event.pathname)

    process_IN_CREATE = process_IN_DELETE = process_IN_MODIFY = process_default
    process_IN_CLOSE_WRITE = process_IN_MOVED_FROM = process_IN_MOVED_TO = process_default
    process_IN_ATTRIB = process_default

def csync_server_wait():
    attempts = 0
    max_attempts = 60  # 30 seconds max wait time
    while attempts < max_attempts:
        if not os.path.exists(csync_log_file) or os.path.getsize(csync_log_file) == 0:
            break
        time.sleep(0.5)
        attempts += 1
        logger.debug(f"Waiting for csync server... Attempt {attempts}/{max_attempts}")
    else:
        logger.warning("Csync server wait timeout reached")

def update_node(node, csync_opts):
    try:
        logger.debug(f"Updating node {node}")
        result = subprocess.run(["csync2"] + csync_opts + ["-ub", "-P", node], 
                                check=True, capture_output=True, text=True)
        logger.debug(f"Node {node} update result: {result.stdout}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Error updating node {node}: {e}")
        logger.error(f"Command output: {e.output}")

def rsync_update(node, source_path, dest_path):
    try:
        logger.debug(f"Rsyncing from {source_path} to {node}:{dest_path}")
        result = subprocess.run(["rsync", "-avz", "--delete", source_path, f"{node}:{dest_path}"], 
                                check=True, capture_output=True, text=True)
        logger.debug(f"Rsync result: {result.stdout}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Rsync error: {e}")
        logger.error(f"Command output: {e.output}")

def csync_full_sync(csync_opts, includes, nodes):
    global last_full_sync
    logger.info("* FULL SYNC")

    csync_server_wait()

    try:
        logger.debug("Running csync2 check")
        result = subprocess.run(["csync2"] + csync_opts + ["-cr"] + includes, 
                                check=True, capture_output=True, text=True)
        logger.debug(f"Csync2 check result: {result.stdout}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Csync2 check error: {e}")
        logger.error(f"Command output: {e.output}")
        return

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(nodes)) as executor:
        list(executor.map(lambda node: update_node(node, csync_opts), nodes))

    last_full_sync = time.time()
    logger.info("  Done")

def reset_queue():
    global queue_line_pos
    logger.info("* RESET QUEUE LOG")
    try:
        open(queue_file, 'w').close()
        queue_line_pos = 1
    except IOError as e:
        logger.error(f"Error resetting queue file: {e}")

def process_changes(csync_opts, includes, nodes, csync_files):
    csync_server_wait()

    if use_rsync and len(csync_files) >= rsync_threshold:
        logger.info(f"Using rsync for large batch: {len(csync_files)} files")
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(nodes)) as executor:
            list(executor.map(lambda args: rsync_update(*args), 
                         [(node, include, include) for node in nodes for include in includes]))
    else:
        try:
            logger.debug(f"Processing {len(csync_files)} files with csync2")
            result = subprocess.run(["csync2"] + csync_opts + ["-cr"] + csync_files, 
                                    check=True, capture_output=True, text=True)
            logger.debug(f"Csync2 process result: {result.stdout}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Csync2 process error: {e}")
            logger.error(f"Command output: {e.output}")
            return
        
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(nodes)) as executor:
            list(executor.map(lambda node: update_node(node, csync_opts), nodes))

    logger.info("  Done")

def process_queue_thread(queue, csync_opts, includes, nodes):
    global queue_line_pos, last_full_sync
    last_process_time = time.time()
    pending_files = set()

    while True:
        try:
            file_path = queue.get(timeout=min(check_interval, max_wait_time - (time.time() - last_process_time)))
            pending_files.add(file_path)
        except queue.Empty:
            if time.time() - last_process_time >= max_wait_time and pending_files:
                logger.info(f"* PROCESSING QUEUE (line {queue_line_pos})")
                queue_line_pos += len(pending_files)
                csync_files = list(pending_files)
                pending_files.clear()

                if len(csync_files) >= num_batched_changes_threshold:
                    logger.info(f"* LARGE BATCH ({len(csync_files)}) files")
                    csync_full_sync(csync_opts, includes, nodes)
                else:
                    process_changes(csync_opts, includes, nodes, csync_files)

                last_process_time = time.time()
            elif queue_line_pos >= num_lines_until_reset:
                reset_queue()
            elif time.time() - last_full_sync > full_sync_interval:
                csync_full_sync(csync_opts, includes, nodes)
            continue

# Async functions remain unchanged

def run_threaded(csync_opts):
    global nodes, includes, excludes, config_file
    nodes, includes, excludes = [], [], []

    try:
        # Parse csync2.cfg
        with open(config_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                key, value = line.split(" ", 1)
                if key == "host":
                    nodes.append(value)
                elif key == "include":
                    includes.append(value)
                elif key == "exclude":
                    excludes.append(value)
    except IOError as e:
        logger.error(f"Error reading config file: {e}")
        return

    if not nodes or not includes:
        logger.error("No nodes or includes found in config file")
        return

    event_queue = queue.Queue()
    wm = pyinotify.WatchManager()
    mask = pyinotify.IN_DELETE | pyinotify.IN_CREATE | pyinotify.IN_MODIFY | \
           pyinotify.IN_CLOSE_WRITE | pyinotify.IN_MOVED_FROM | pyinotify.IN_MOVED_TO | \
           pyinotify.IN_ATTRIB
    handler = ChangeEventHandler(event_queue)
    notifier = pyinotify.ThreadedNotifier(wm, handler)
    notifier.start()

    for include_path in includes:
        try:
            wm.add_watch(include_path, mask, rec=True, auto_add=True)
        except pyinotify.WatchManagerError as e:
            logger.error(f"Error adding watch for {include_path}: {e}")

    try:
        csync_server = subprocess.Popen(["csync2", "-ii", "-t"] + csync_opts, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except subprocess.SubprocessError as e:
        logger.error(f"Error starting csync2 server: {e}")
        return

    process_queue_thread = threading.Thread(target=process_queue_thread, args=(event_queue, csync_opts, includes, nodes))
    process_queue_thread.start()

    def signal_handler(signum, frame):
        logger.info("Stopping notifier and csync server...")
        notifier.stop()
        csync_server.terminate()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        notifier.stop()
        process_queue_thread.join()
        csync_server.wait()

# Async run function remains unchanged

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Csync2 controller')
    parser.add_argument('--config', type=str, default="/etc/csync2/csync2.cfg", help='Path to csync2 config file')
    parser.add_argument('--check-interval', type=float, default=0.5, help='Interval between queue checks')
    parser.add_argument('--full-sync-interval', type=int, default=3600, help='Interval between full syncs')
    parser.add_argument('--num-lines-until-reset', type=int, default=200000, help='Number of lines until queue reset')
    parser.add_argument('--num-batched-changes-threshold', type=int, default=15000, help='Threshold for batch processing')
    parser.add_argument('--rsync-threshold', type=int, default=5000, help='Threshold for using rsync instead of csync2')
    parser.add_argument('--parallel-updates', type=int, default=1, help='Enable parallel updates')
    parser.add_argument('--max-wait-time', type=int, default=10, help='Maximum wait time before processing queue')
    parser.add_argument('-m', '--mode', choices=['async', 'thread'], default='async', help='Execution mode (async or thread)')
    parser.add_argument('--disable-rsync', action='store_true', help='Disable the use of rsync for large batches')
    parser.add_argument('--debug', action='store_true', help='Enable debug logging')
    args, csync_opts = parser.parse_known_args()

    if args.debug:
        logger.setLevel(logging.DEBUG)

    config_file = args.config
    check_interval = args.check_interval
    full_sync_interval = args.full_sync_interval
    num_lines_until_reset = args.num_lines_until_reset
    num_batched_changes_threshold = args.num_batched_changes_threshold
    rsync_threshold = args.rsync_threshold
    parallel_updates = args.parallel_updates
    max_wait_time = args.max_wait_time
    use_rsync = not args.disable_rsync

    try:
        if args.mode == 'async':
            asyncio.run(run_async(csync_opts))
        else:
            run_threaded(csync_opts)
    except Exception as e:
        logger.critical(f"Unhandled exception: {e}")
        logger.debug(traceback.format_exc())
        sys.exit(1)

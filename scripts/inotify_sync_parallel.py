#!/usr/bin/env python3

import os
import queue
import threading
import subprocess
import time
import signal
import shlex
import logging
import argparse
import concurrent.futures
import pyinotify

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(message)s')
logger = logging.getLogger(__name__)

# Global variables
queue_file = "/home/csync2-inotify/tmp/inotify_queue.log"
csync_log_file = "/home/csync2-inotify/tmp/csync_server.log"
check_interval = 0.5
full_sync_interval = 3600
num_lines_until_reset = 200000
num_batched_changes_threshold = 15000
parallel_updates = 1
max_wait_time = 10  # seconds
last_full_sync = 0
queue_line_pos = 1
config_file = "/etc/csync2/csync2.cfg"

class ChangeEventHandler(pyinotify.ProcessEvent):
    def __init__(self, queue):
        self.queue = queue

    def process_IN_CREATE(self, event):
        self.queue.put(event.pathname)

    def process_IN_DELETE(self, event):
        self.queue.put(event.pathname)

    def process_IN_MODIFY(self, event):
        self.queue.put(event.pathname)

    def process_IN_CLOSE_WRITE(self, event):
        self.queue.put(event.pathname)

    def process_IN_MOVED_FROM(self, event):
        self.queue.put(event.pathname)

    def process_IN_MOVED_TO(self, event):
        self.queue.put(event.pathname)

    def process_IN_ATTRIB(self, event):
        self.queue.put(event.pathname)

def csync_server_wait(csync_log_file):
    while True:
        if not os.path.exists(csync_log_file) or os.path.getsize(csync_log_file) == 0:
            break
        time.sleep(0.5)
        logger.info("...waiting for csync server...")

def update_node(node, csync_opts):
    subprocess.run(["csync2"] + csync_opts + ["-ub", "-P", node], check=True)

def csync_full_sync(csync_opts, includes, nodes):
    global last_full_sync
    logger.info("* FULL SYNC")

    csync_server_wait(csync_log_file)

    subprocess.run(["csync2"] + csync_opts + ["-cr"] + includes, check=True)
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(nodes)) as executor:
        executor.map(lambda node: update_node(node, csync_opts), nodes)

    last_full_sync = time.time()
    logger.info("  Done")

def reset_queue(queue_file):
    global queue_line_pos
    logger.info("* RESET QUEUE LOG")
    open(queue_file, 'w').close()
    queue_line_pos = 1

def process_changes(csync_opts, includes, nodes, csync_files):
    csync_server_wait(csync_log_file)

    subprocess.run(["csync2"] + csync_opts + ["-cr"] + csync_files, check=True)
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(nodes)) as executor:
        executor.map(lambda node: update_node(node, csync_opts), nodes)

    logger.info("  Done")

def process_queue(queue, csync_opts, includes, nodes):
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
                reset_queue(queue_file)
            elif time.time() - last_full_sync > full_sync_interval:
                csync_full_sync(csync_opts, includes, nodes)
            continue

def main(csync_opts):
    global nodes, includes, excludes, config_file
    nodes, includes, excludes = [], [], []

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

    event_queue = queue.Queue()
    wm = pyinotify.WatchManager()
    mask = pyinotify.IN_DELETE | pyinotify.IN_CREATE | pyinotify.IN_MODIFY | \
           pyinotify.IN_CLOSE_WRITE | pyinotify.IN_MOVED_FROM | pyinotify.IN_MOVED_TO | \
           pyinotify.IN_ATTRIB
    handler = ChangeEventHandler(event_queue)
    notifier = pyinotify.ThreadedNotifier(wm, handler)
    notifier.start()

    for include_path in includes:
        wm.add_watch(include_path, mask, rec=True, auto_add=True)

    csync_server = subprocess.Popen(["csync2", "-ii", "-t"] + csync_opts, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    process_queue_thread = threading.Thread(target=process_queue, args=(event_queue, csync_opts, includes, nodes))
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

    notifier.stop()
    process_queue_thread.join()
    csync_server.wait()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Csync2 controller')
    parser.add_argument('--config', type=str, default="/etc/csync2/csync2.cfg", help='Path to csync2 config file')
    parser.add_argument('--check-interval', type=float, default=0.5, help='Interval between queue checks')
    parser.add_argument('--full-sync-interval', type=int, default=3600, help='Interval between full syncs')
    parser.add_argument('--num-lines-until-reset', type=int, default=200000, help='Number of lines until queue reset')
    parser.add_argument('--num-batched-changes-threshold', type=int, default=15000, help='Threshold for batch processing')
    parser.add_argument('--parallel-updates', type=int, default=1, help='Enable parallel updates')
    parser.add_argument('--max-wait-time', type=int, default=10, help='Maximum wait time before processing queue')
    args, csync_opts = parser.parse_known_args()

    config_file = args.config
    check_interval = args.check_interval
    full_sync_interval = args.full_sync_interval
    num_lines_until_reset = args.num_lines_until_reset
    num_batched_changes_threshold = args.num_batched_changes_threshold
    parallel_updates = args.parallel_updates
    max_wait_time = args.max_wait_time

    main(csync_opts)
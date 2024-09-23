#!/usr/bin/env python3

import os
import subprocess
import time
import logging
import argparse
import pyinotify

# Setup logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Global variables
queue_file = "/home/csync2-inotify/tmp/inotify_queue_python.log"
csync_log_file = "/home/csync2-inotify/tmp/csync_server_python.log"
config_file = "/etc/csync2/csync2.cfg"
check_interval = 0.5
full_sync_interval = 3600
num_batched_changes_threshold = 15000
last_full_sync = 0

def ensure_directory_exists(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)

def ensure_file_exists(path):
    open(path, 'a').close()

def initialize_environment():
    ensure_directory_exists(queue_file)
    ensure_directory_exists(csync_log_file)
    ensure_file_exists(queue_file)
    ensure_file_exists(csync_log_file)

def parse_config_file(config_file):
    nodes, includes, excludes = [], [], []
    with open(config_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith("host"):
                nodes.append(line.split(None, 1)[1].rstrip(';'))
            elif line.startswith("include"):
                includes.append(line.split(None, 1)[1].rstrip(';'))
            elif line.startswith("exclude"):
                excludes.append(line.split(None, 1)[1].rstrip(';'))
    return nodes, includes, excludes

class ChangeEventHandler(pyinotify.ProcessEvent):
    def process_default(self, event):
        if not event.name.startswith('.') and not event.name.endswith(('.tmp', '.swp')):
            logger.debug(f"Detected event: {event.maskname} on {event.pathname}")
            with open(queue_file, 'a') as f:
                f.write(f"{event.pathname}\n")

def csync_full_sync(csync_opts, includes, nodes):
    global last_full_sync
    logger.info("* FULL SYNC")
    try:
        subprocess.run(["csync2", "-xv"] + csync_opts, check=True)
        last_full_sync = time.time()
        logger.info("  Full sync completed")
    except subprocess.CalledProcessError as e:
        logger.error(f"Full sync failed: {e}")

def process_changes(csync_opts, csync_files):
    try:
        logger.debug(f"Processing {len(csync_files)} files with csync2")
        subprocess.run(["csync2", "-u"] + csync_opts + csync_files, check=True)
        logger.info("  Changes processed")
    except subprocess.CalledProcessError as e:
        logger.error(f"Error processing changes: {e}")

def main(csync_opts):
    initialize_environment()
    nodes, includes, excludes = parse_config_file(config_file)

    wm = pyinotify.WatchManager()
    mask = pyinotify.IN_DELETE | pyinotify.IN_CREATE | pyinotify.IN_MODIFY | \
           pyinotify.IN_CLOSE_WRITE | pyinotify.IN_MOVED_FROM | pyinotify.IN_MOVED_TO | \
           pyinotify.IN_ATTRIB
    handler = ChangeEventHandler()
    notifier = pyinotify.Notifier(wm, handler)

    for include_path in includes:
        wm.add_watch(include_path, mask, rec=True, auto_add=True)

    csync_server = subprocess.Popen(["csync2", "-ii", "-t"] + csync_opts,
                                    stdout=open(csync_log_file, 'w'),
                                    stderr=subprocess.STDOUT)

    logger.info("Starting inotify watch and csync2 processing")
    last_process_time = time.time()

    try:
        while True:
            if notifier.check_events(timeout=1000):
                notifier.read_events()
                notifier.process_events()

            current_time = time.time()
            if current_time - last_process_time >= check_interval:
                with open(queue_file, 'r') as f:
                    csync_files = list(set(f.read().splitlines()))

                if csync_files:
                    if len(csync_files) >= num_batched_changes_threshold or \
                       current_time - last_full_sync >= full_sync_interval:
                        csync_full_sync(csync_opts, includes, nodes)
                    else:
                        process_changes(csync_opts, csync_files)

                    open(queue_file, 'w').close()  # Clear the queue file
                last_process_time = current_time

    except KeyboardInterrupt:
        logger.info("Stopping inotify watch and csync2 processing")
    finally:
        notifier.stop()
        csync_server.terminate()
        csync_server.wait()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Csync2 controller')
    parser.add_argument('--debug', action='store_true', help='Enable debug logging')
    args, csync_opts = parser.parse_known_args()

    if args.debug:
        logger.setLevel(logging.DEBUG)

    main(csync_opts)
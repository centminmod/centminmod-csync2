#!/usr/bin/env python3

import os
import subprocess
import logging
import argparse
import pyinotify
import signal
import sys
import time

logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

config_file = "/etc/csync2/csync2.cfg"
csync_log_file = "/home/csync2-inotify/tmp/csync_server_python.log"
queue_file = "/home/csync2-inotify/tmp/inotify_queue.log"

def parse_config_file(config_file):
    includes = []
    with open(config_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith("include"):
                includes.append(line.split(None, 1)[1].rstrip(';'))
    return includes

class ChangeHandler(pyinotify.ProcessEvent):
    def __init__(self, csync_opts):
        self.csync_opts = csync_opts
        self.last_sync = time.time()
        self.sync_interval = 5  # seconds
        self.max_batch_size = 1000

    def process_IN_CLOSE_WRITE(self, event):
        self.add_to_queue(event.pathname)

    def process_IN_CREATE(self, event):
        self.add_to_queue(event.pathname)

    def process_IN_DELETE(self, event):
        self.add_to_queue(event.pathname)

    def process_IN_MOVED_TO(self, event):
        self.add_to_queue(event.pathname)

    def add_to_queue(self, filepath):
        with open(queue_file, 'a') as f:
            f.write(f"{filepath}\n")
        self.check_sync()

    def check_sync(self):
        current_time = time.time()
        if current_time - self.last_sync >= self.sync_interval:
            self.sync_changes()

    def sync_changes(self):
        if not os.path.exists(queue_file) or os.path.getsize(queue_file) == 0:
            return

        with open(queue_file, 'r') as f:
            changes = f.readlines()

        logger.info(f"Syncing {len(changes)} files")
        
        batch = []
        for change in changes:
            batch.append(change.strip())
            if len(batch) >= self.max_batch_size:
                self.sync_batch(batch)
                batch = []

        if batch:
            self.sync_batch(batch)

        open(queue_file, 'w').close()  # Clear the queue file
        self.last_sync = time.time()

    def sync_batch(self, batch):
        try:
            result = subprocess.run(["csync2", "-x", "-v"] + self.csync_opts + batch, 
                                    capture_output=True, text=True, check=True)
            logger.debug(f"Csync2 output: {result.stdout}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Csync2 error: {e}")
            logger.error(f"Csync2 error output: {e.stderr}")

def start_csync2_daemon(csync_opts):
    logger.info("Starting csync2 daemon")
    try:
        csync_server = subprocess.Popen(["csync2", "-ii", "-v", "-t"] + csync_opts,
                                        stdout=open(csync_log_file, 'w'),
                                        stderr=subprocess.STDOUT)
        return csync_server
    except subprocess.SubprocessError as e:
        logger.error(f"Error starting csync2 daemon: {e}")
        sys.exit(1)

def main(csync_opts):
    includes = parse_config_file(config_file)
    logger.info(f"Configured includes: {includes}")

    csync_server = start_csync2_daemon(csync_opts)

    wm = pyinotify.WatchManager()
    mask = pyinotify.IN_CLOSE_WRITE | pyinotify.IN_CREATE | pyinotify.IN_DELETE | pyinotify.IN_MOVED_TO
    handler = ChangeHandler(csync_opts)
    notifier = pyinotify.Notifier(wm, handler)

    for include_path in includes:
        wm.add_watch(include_path, mask, rec=True, auto_add=True)
        logger.info(f"Watching directory: {include_path}")

    logger.info("Starting inotify watch")
    
    def signal_handler(signum, frame):
        logger.info("Received signal to terminate. Stopping csync2 daemon and inotify watch.")
        handler.sync_changes()  # Sync any remaining changes
        csync_server.terminate()
        notifier.stop()
        sys.exit(0)

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    try:
        while True:
            if notifier.check_events(timeout=1000):
                notifier.read_events()
                notifier.process_events()
            handler.check_sync()
    except KeyboardInterrupt:
        logger.info("Keyboard interrupt received. Stopping inotify watch and csync2 daemon.")
    finally:
        handler.sync_changes()  # Sync any remaining changes
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
I run csync 2.1.1 fork with shell inotify_sync.sh script as a service but also tried creating python version but only shell version seems to work when testing 2 server host1 and host2 system creating files on host1 csync2 sync properly to host2 with shell version but not python version. Only way python version syncs for host2 is if i manually run `systemctl restart inotify_csync.service` on host1 ?

inotify_sync.sh

```
On `host1`


`/etc/systemd/system/inotify_csync.service`

```
[Unit]
Description=Inotify Csync2 Sync Service
After=network.target

[Service]
Type=simple
# Pre-start script to kill any running csync2 processes
ExecStartPre=/bin/bash -c 'pgrep -f csync2 && killall csync2 || true'
# Start the csync2 service
ExecStart=/usr/local/bin/inotify_csync -N host1
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/home/csync2-inotify

[Install]
WantedBy=multi-user.target
```

On `host2`


`/etc/systemd/system/inotify_csync.service`

```
[Unit]
Description=Inotify Csync2 Sync Service
After=network.target

[Service]
Type=simple
# Pre-start script to kill any running csync2 processes
ExecStartPre=/bin/bash -c 'pgrep -f csync2 && killall csync2 || true'
# Start the csync2 service
ExecStart=/usr/local/bin/inotify_csync -N host2
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/home/csync2-inotify

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable inotify_csync.service
sudo systemctl start inotify_csync.service
sudo journalctl -u inotify_csync.service --no-pager | tail -25
sudo systemctl status inotify_csync.service --no-pager -l
```
```

```bash
#!/bin/bash

# Watch csync directories and sync changes via csync2
#
# $1: csync2 options to passthrough


# --- SETTINGS ---

file_events="move,delete,attrib,create,close_write,modify"       # File events to monitor - no spaces in this list
queue_file=/home/csync2-inotify/tmp/inotify_queue.log            # File used for event queue
csync_log=/home/csync2-inotify/tmp/csync_server.log              # File used for monitoring csync server timings
mkdir -p /home/csync2-inotify/tmp

check_interval=0.5                   # Seconds between queue checks - fractions allowed
full_sync_interval=$((60*60))        # Seconds between a regular full sync - zero to turn off
num_lines_until_reset=200000         # Reset queue log file after reading this many lines
num_batched_changes_threshold=15000  # Number of changes in one batch that will trigger a full sync and reset
parallel_updates=1                   # Flag (0/1) to toggle updating of peers/nodes in parallel

#cfg_path=/usr/local/etc
cfg_path=/etc/csync2
cfg_file=csync2.cfg

# Separate all passed options for csync
csync_opts=("$@")


# --- VERSION ---

echo "CSync Controller"
echo "Version 18 Sep 2024"
echo
echo "Passed options: ${csync_opts[*]}"
echo
echo "* SETTINGS"
echo "  check_interval                = ${check_interval}s"
echo "  full_sync_interval            = ${full_sync_interval}s"
echo "  num_lines_until_reset         = $num_lines_until_reset"
echo "  num_batched_changes_threshold = $num_batched_changes_threshold"
echo "  parallel_updates              = $parallel_updates"


# --- CSYNC SERVER ---

# Extract server-specific options
server_opts=()
if [[ $* =~ -N[[:space:]]?([[:alnum:]\.]+) ]]  # hostname
then
    this_node=${BASH_REMATCH[1]}
    server_opts+=(-N "$this_node") # added as two elements
else
    echo "*** WARNING: No hostname specified ***"
    sleep 2
fi
if [[ $* =~ -D[[:space:]]?([[:graph:]]+) ]]    # database path
then
    server_opts+=(-D "${BASH_REMATCH[1]}")
fi

echo
echo "* SERVER"
echo "  Options: ${server_opts[*]}"

# Start csync server outputting timings to log for monitoring activity status
csync2 -ii -t "${server_opts[@]}" &> $csync_log &
csync_pid=$!

# Wait for server startup then check
sleep 0.5
if ! ps --pid $csync_pid > /dev/null
then
    echo "Failed to start csync server"
    exit 1
fi

# Stop background csync server on exit
trap 'kill $csync_pid' EXIT

echo "  Running..."


# --- PARSE CSYNC CONFIG FILE ---

# Parse csync2 config file for included and excluded locations
while read -r key value
do
    # Ignore comments and blank lines
    if [[ ! $key =~ ^\ *# && -n $key ]]
    then
        if [[ $key == "host" && $value != $this_node* ]]
        then
            nodes+=("${value%;}")
        elif [[ $key == "include" ]]
        then
            includes+=("${value%;}")
        elif [[ $key == "exclude" ]]
        then
            excludes+=("${value%;}")
        fi
    fi
done < "$cfg_path/$cfg_file"

echo
echo "* CONFIG"
echo "  Peers:    ${nodes[*]}"
echo "  Includes: ${includes[*]}"
echo "  Excludes: ${excludes[*]}"

if [[ ${#includes[@]} -eq 0 ]]
then
    echo "No include locations found"
    exit 1
fi


# --- INOTIFY FILE MONITOR ---

echo
echo "* INOTIFY"

# Reset queue file
truncate -s 0 $queue_file

# Monitor for events in the background and add altered files to queue file
while read -r file
do
    # Check if excluded
    for excluded in "${excludes[@]}"
    do
        if [[ $file == $excluded* ]]
        then
            # Excluded - skip this file and return to inotifywait
            continue 2
        fi
    done

    # Add file to queue
    echo "$file" >> $queue_file

done < <(inotifywait --monitor --recursive --event $file_events --format "%w%f" "${includes[@]}") &

inotify_pid=$!

# Stop background inotify monitor and csync server on exit
trap 'kill $inotify_pid; kill $csync_pid' EXIT

sleep 1
echo "  Running..."


# --- HELPERS ---

# Wait until csync server is quiet
function csync_server_wait()
{
    # Wait until the end timestamp record appears in the last log line or if the file is empty
    until tail --lines=1 $csync_log | grep --quiet TOTALTIME || [[ ! -s $csync_log ]]
    do
        echo "...waiting for csync server..."
        sleep $check_interval
    done
}


# Run a full check and sync operation
function csync_full_sync()
{
    echo
    echo "* FULL SYNC"

    # First wait until csync server is quiet
    csync_server_wait

    if (( parallel_updates ))
    then
        # Check files separately from parallel update
        echo "  Checking all files"
        csync2 "${csync_opts[@]}" -cr "/"

        # Update each node in parallel
        update_pids=()
        for node in "${nodes[@]}"
        do
            echo "  Updating $node"
            csync2 "${csync_opts[@]}" -ub -P "$node" &
            update_pids+=($!)
        done
        wait "${update_pids[@]}"
    else
        # Check nodes in sequence
        echo "  Checking and updating peers sequentially"
        csync2 "${csync_opts[@]}" -x
    fi

    last_full_sync=$(date +%s)
    echo "  Done"
}


# Reset queue
function reset_queue()
{
    echo
    echo "* RESET QUEUE LOG"

    # Reset queue log file
    truncate -s 0 $queue_file
    queue_line_pos=1

    # Run a full sync in case inotify triggered during reset
    csync_full_sync

    # Reset csync server log too
    truncate -s 0 $csync_log
}


# --- QUEUE PROCESSING ---

# Run a full check and sync before queue processing begins - after file monitor started so no changes are missed in-between
csync_full_sync


# Periodically monitor inotify queue file
queue_line_pos=1
last_full_sync=$(date +%s)
while true
do
    # Delay between updates to allow for batches of inotify events to be gathered
    sleep $check_interval

    # Make array starting from last read position in queue file
    mapfile -t file_list < <(tail --lines=+$queue_line_pos $queue_file)

    if [[ ${#file_list[@]} -eq 0 ]]
    then
        # No new entries - quiet time

        # Check for reset
        if [[ $queue_line_pos -ge $num_lines_until_reset ]]
        then
            reset_queue

        # Check for regular full sync
        elif (( full_sync_interval && ($(date +%s) - last_full_sync) > full_sync_interval ))
        then
            csync_full_sync
        fi

        # Jump back to sleep
        continue
    fi

    echo
    echo "* PROCESSING QUEUE (line $queue_line_pos)"

    # Advance queue file position
    ((queue_line_pos+=${#file_list[@]}))

    # Remove duplicates
    mapfile -t csync_files < <(printf "%s\n" "${file_list[@]}" | sort -u)

    # DEBUG: Output files processed in each cycle
    # printf "%s\n" "${csync_files[@]}" >> "/tmp/csync_$(date +%s%3N).log"

    # Check number of files in this batch
    if [[ ${#csync_files[@]} -ge $num_batched_changes_threshold ]]
    then
        # Large batch - run full sync and reset
        # This avoids breaching any max file argument limits and also acts as a safety net if inotify misses events when there are many changing files
        echo "* LARGE BATCH (${#csync_files[@]} files)"

        csync_full_sync

        # Jump back to sleep
        continue
    fi

    # Wait until csync server is quiet
    csync_server_wait

    # Process files by sending csync commands
    # Split into two stages so that outstanding dirty files can be processed regardless of when or where they were marked

    #   1. Check and possibly mark queued files as dirty - recursive so nested dirs are handled even if inotify misses them
    echo "  Checking ${#csync_files[@]} files"
    csync2 "${csync_opts[@]}" -cr "${csync_files[@]}"

    #   2. Update outstanding dirty files on peers
    if (( parallel_updates ))
    then
        # Update each node in parallel
        update_pids=()
        for node in "${nodes[@]}"
        do
            echo "  Updating $node"
            csync2 "${csync_opts[@]}" -ub -P "$node" &
            update_pids+=($!)
        done
        wait "${update_pids[@]}"
    else
        # Update nodes in sequence
        echo "  Updating peers sequentially"
        csync2 "${csync_opts[@]}" -u
    fi

    echo "  Done"
done
```

inotify_async_asyncio.sh

```
On `host1`


`/etc/systemd/system/inotify_csync.service`

```
[Unit]
Description=Inotify Csync2 Sync Service
After=network.target

[Service]
Type=simple
# Pre-start script to kill any running csync2 processes
ExecStartPre=/bin/bash -c 'pgrep -f csync2 && killall csync2 || true'
# Start the csync2 service
ExecStart=/usr/local/bin/inotify_csync_asyncio.py -N host1
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/home/csync2-inotify

[Install]
WantedBy=multi-user.target
```

On `host2`


`/etc/systemd/system/inotify_csync.service`

```
[Unit]
Description=Inotify Csync2 Sync Service
After=network.target

[Service]
Type=simple
# Pre-start script to kill any running csync2 processes
ExecStartPre=/bin/bash -c 'pgrep -f csync2 && killall csync2 || true'
# Start the csync2 service
ExecStart=/usr/local/bin/inotify_csync_asyncio.py -N host2
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/home/csync2-inotify

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable inotify_csync.service
sudo systemctl start inotify_csync.service
sudo journalctl -u inotify_csync.service --no-pager | tail -25
sudo systemctl status inotify_csync.service --no-pager -l
```
```

```python
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

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

queue_file = "/home/csync2-inotify/tmp/inotify_queue_python.log"
csync_log_file = "/home/csync2-inotify/tmp/csync_server_python.log"
check_interval = 0.5
full_sync_interval = 3600
num_lines_until_reset = 200000
num_batched_changes_threshold = 15000
rsync_threshold = 5000
parallel_updates = 1
max_wait_time = 10
last_full_sync = 0
queue_line_pos = 1
config_file = "/etc/csync2/csync2.cfg"
use_rsync = False

# Global flag for graceful shutdown
shutdown_flag = False

def ensure_directory_exists(path):
    try:
        os.makedirs(path, exist_ok=True)
        logger.debug(f"Ensured directory exists: {path}")
    except Exception as e:
        logger.error(f"Failed to create directory {path}: {e}")
        raise

def ensure_file_exists(path):
    try:
        with open(path, 'a'):
            pass
        logger.debug(f"Ensured file exists: {path}")
    except Exception as e:
        logger.error(f"Failed to create file {path}: {e}")
        raise

def initialize_environment():
    ensure_directory_exists(os.path.dirname(queue_file))
    ensure_directory_exists(os.path.dirname(csync_log_file))
    ensure_file_exists(queue_file)
    ensure_file_exists(csync_log_file)
    if not os.path.exists(config_file):
        logger.error(f"Configuration file not found: {config_file}")
        raise FileNotFoundError(f"Configuration file not found: {config_file}")

class ChangeEventHandler(pyinotify.ProcessEvent):
    def __init__(self, queue):
        self.queue = queue

    def process_default(self, event):
        logger.debug(f"Detected event: {event.maskname} on {event.pathname}")
        # Add to the queue in a non-async way
        self.queue.put_nowait(event.pathname)

    process_IN_CREATE = process_IN_DELETE = process_IN_MODIFY = process_default
    process_IN_CLOSE_WRITE = process_IN_MOVED_FROM = process_IN_MOVED_TO = process_default
    process_IN_ATTRIB = process_default

def csync_server_wait():
    attempts = 0
    max_attempts = 60
    while attempts < max_attempts and not shutdown_flag:
        if not os.path.exists(csync_log_file) or os.path.getsize(csync_log_file) == 0:
            break
        time.sleep(0.5)
        attempts += 1
        logger.debug(f"Waiting for csync server... Attempt {attempts}/{max_attempts}")
    else:
        logger.warning("Csync server wait timeout reached")

def reset_queue():
    global queue_line_pos
    logger.info("* RESET QUEUE LOG")
    try:
        open(queue_file, 'w').close()
        queue_line_pos = 1
    except IOError as e:
        logger.error(f"Error resetting queue file: {e}")

async def csync_full_sync(csync_opts, includes, nodes):
    global last_full_sync
    logger.info("* FULL SYNC")

    csync_server_wait()
    if shutdown_flag:
        return

    try:
        logger.debug("Running csync2 check")
        process = await asyncio.create_subprocess_exec(
            "csync2", *csync_opts, "-cr", *includes,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        logger.debug(f"Csync2 check result: {stdout.decode()}")
        if stderr:
            logger.error(f"Csync2 check error: {stderr.decode()}")
    except Exception as e:
        logger.error(f"Error during csync2 check: {e}")
        return

    update_tasks = [update_node_async(node, csync_opts) for node in nodes]
    await asyncio.gather(*update_tasks)

    last_full_sync = time.time()
    logger.info("  Done")

async def update_node_async(node, csync_opts):
    try:
        logger.debug(f"Updating node {node}")
        process = await asyncio.create_subprocess_exec(
            "csync2", *csync_opts, "-ub", "-P", node,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        logger.debug(f"Node {node} update result: {stdout.decode()}")
        if stderr:
            logger.error(f"Error updating node {node}: {stderr.decode()}")
    except Exception as e:
        logger.error(f"Exception while updating node {node}: {e}")

async def process_changes_async(csync_opts, includes, nodes, csync_files):
    csync_server_wait()
    if shutdown_flag:
        return

    if use_rsync and len(csync_files) >= rsync_threshold:
        logger.info(f"Using rsync for large batch: {len(csync_files)} files")
        rsync_tasks = [rsync_update_async(node, include, include) for node in nodes for include in includes]
        await asyncio.gather(*rsync_tasks)
    else:
        try:
            logger.debug(f"Processing {len(csync_files)} files with csync2")
            process = await asyncio.create_subprocess_exec(
                "csync2", *csync_opts, "-cr", *csync_files,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await process.communicate()
            logger.debug(f"Csync2 process result: {stdout.decode()}")
            if stderr:
                logger.error(f"Csync2 process error: {stderr.decode()}")
        except Exception as e:
            logger.error(f"Error during csync2 process: {e}")
            return
        
        update_tasks = [update_node_async(node, csync_opts) for node in nodes]
        await asyncio.gather(*update_tasks)

    logger.info("  Done")

async def rsync_update_async(node, source_path, dest_path):
    try:
        logger.debug(f"Rsyncing from {source_path} to {node}:{dest_path}")
        process = await asyncio.create_subprocess_exec(
            "rsync", "-avz", "--delete", source_path, f"{node}:{dest_path}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, stderr = await process.communicate()
        logger.debug(f"Rsync result: {stdout.decode()}")
        if stderr:
            logger.error(f"Rsync error: {stderr.decode()}")
    except Exception as e:
        logger.error(f"Exception during rsync: {e}")

def parse_config_file(config_file):
    nodes, includes, excludes = [], [], []
    try:
        with open(config_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or line == "}":
                    continue
                parts = line.split(None, 1)
                if len(parts) != 2:
                    logger.warning(f"Skipping invalid line in config: {line}")
                    continue
                key, value = parts
                value = value.rstrip(';').strip()
                if key == "host":
                    nodes.append(value)
                elif key == "include":
                    includes.append(value)
                elif key == "exclude":
                    excludes.append(value)
    except IOError as e:
        logger.error(f"Error reading config file: {e}")
        raise
    return nodes, includes, excludes

async def run_async(csync_opts):
    global nodes, includes, excludes, config_file, shutdown_flag

    nodes, includes, excludes = parse_config_file(config_file)

    if not nodes or not includes:
        logger.error("No nodes or includes found in config file")
        return

    event_queue = asyncio.Queue()
    wm = pyinotify.WatchManager()
    mask = pyinotify.IN_DELETE | pyinotify.IN_CREATE | pyinotify.IN_MODIFY | \
           pyinotify.IN_CLOSE_WRITE | pyinotify.IN_MOVED_FROM | pyinotify.IN_MOVED_TO | \
           pyinotify.IN_ATTRIB
    handler = ChangeEventHandler(event_queue)
    notifier = pyinotify.AsyncioNotifier(wm, asyncio.get_event_loop(), default_proc_fun=handler)

    for include_path in includes:
        try:
            if not os.path.exists(include_path):
                logger.warning(f"Directory does not exist: {include_path}. Creating it.")
                os.makedirs(include_path, exist_ok=True)
            wm.add_watch(include_path, mask, rec=True, auto_add=True)
        except pyinotify.WatchManagerError as e:
            logger.error(f"Error adding watch for {include_path}: {e}")

    csync_server = await asyncio.create_subprocess_exec(
        "csync2", "-ii", "-t", *csync_opts,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT
    )

    queue_task = asyncio.create_task(process_queue_async(event_queue, csync_opts, includes, nodes))

    def signal_handler():
        global shutdown_flag
        logger.info("Received shutdown signal. Initiating graceful shutdown...")
        shutdown_flag = True
        queue_task.cancel()
        csync_server.terminate()

    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGINT, signal_handler)
    loop.add_signal_handler(signal.SIGTERM, signal_handler)

    try:
        await asyncio.gather(csync_server.wait(), queue_task)
    except asyncio.CancelledError:
        logger.info("Tasks cancelled. Shutting down...")
    finally:
        notifier.stop()
        logger.info("Shutdown complete.")

async def process_queue_async(queue, csync_opts, includes, nodes):
    global queue_line_pos, last_full_sync, shutdown_flag
    last_process_time = time.time()
    pending_files = set()

    while not shutdown_flag:
        try:
            file_path = await asyncio.wait_for(queue.get(), timeout=min(check_interval, max_wait_time - (time.time() - last_process_time)))
            pending_files.add(file_path)
        except asyncio.TimeoutError:
            if shutdown_flag:
                break
            if time.time() - last_process_time >= max_wait_time and pending_files:
                logger.info(f"* PROCESSING QUEUE (line {queue_line_pos})")
                queue_line_pos += len(pending_files)
                csync_files = list(pending_files)
                pending_files.clear()

                if len(csync_files) >= num_batched_changes_threshold:
                    logger.info(f"* LARGE BATCH ({len(csync_files)}) files")
                    await csync_full_sync(csync_opts, includes, nodes)
                else:
                    await process_changes_async(csync_opts, includes, nodes, csync_files)

                last_process_time = time.time()
            elif queue_line_pos >= num_lines_until_reset:
                reset_queue()
            elif time.time() - last_full_sync > full_sync_interval:
                await csync_full_sync(csync_opts, includes, nodes)
        except asyncio.CancelledError:
            logger.info("Queue processing cancelled.")
            break
    
    logger.info("Queue processing stopped.")

def run_threaded(csync_opts):
    global nodes, includes, excludes, config_file, shutdown_flag

    nodes, includes, excludes = parse_config_file(config_file)

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
            if not os.path.exists(include_path):
                logger.warning(f"Directory does not exist: {include_path}. Creating it.")
                os.makedirs(include_path, exist_ok=True)
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

    def signal_handler():
        global shutdown_flag
        logger.info("Received shutdown signal. Initiating graceful shutdown...")
        shutdown_flag = True
        queue_task.cancel()

        # Safely terminate the subprocess, check if transport exists
        if csync_server._transport is None or csync_server._transport.is_closing():
            logger.info("Csync2 server process already terminated or never started.")
        else:
            try:
                csync_server.terminate()  # This safely terminates the subprocess
                logger.info("Csync2 server terminated.")
            except ProcessLookupError:
                logger.info("Csync2 server process not found. It might have already been terminated.")

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        while not shutdown_flag:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Keyboard interrupt received. Initiating graceful shutdown...")
        shutdown_flag = True
    finally:
        notifier.stop()
        process_queue_thread.join()
        csync_server.wait()
        logger.info("Shutdown complete.")

def process_queue_thread(queue, csync_opts, includes, nodes):
    global queue_line_pos, last_full_sync, shutdown_flag
    last_process_time = time.time()
    pending_files = set()

    while not shutdown_flag:
        try:
            file_path = queue.get(timeout=min(check_interval, max_wait_time - (time.time() - last_process_time)))
            pending_files.add(file_path)
        except queue.Empty:
            if shutdown_flag:
                break
            if time.time() - last_process_time >= max_wait_time and pending_files:
                logger.info(f"* PROCESSING QUEUE (line {queue_line_pos})")
                queue_line_pos += len(pending_files)
                csync_files = list(pending_files)
                pending_files.clear()

                if len(csync_files) >= num_batched_changes_threshold:
                    logger.info(f"* LARGE BATCH ({len(csync_files)}) files")
                    csync_full_sync_threaded(csync_opts, includes, nodes)
                else:
                    process_changes_threaded(csync_opts, includes, nodes, csync_files)

                last_process_time = time.time()
            elif queue_line_pos >= num_lines_until_reset:
                reset_queue()
            elif time.time() - last_full_sync > full_sync_interval:
                csync_full_sync_threaded(csync_opts, includes, nodes)
    
    logger.info("Queue processing stopped.")

def update_node_threaded(node, csync_opts):
    if shutdown_flag:
        return
    try:
        logger.debug(f"Updating node {node}")
        result = subprocess.run(["csync2"] + csync_opts + ["-ub", "-P", node], 
                                check=True, capture_output=True, text=True)
        logger.debug(f"Node {node} update result: {result.stdout}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Error updating node {node}: {e}")
        logger.error(f"Command output: {e.output}")

def rsync_update_threaded(node, source_path, dest_path):
    if shutdown_flag:
        return
    try:
        logger.debug(f"Rsyncing from {source_path} to {node}:{dest_path}")
        result = subprocess.run(["rsync", "-avz", "--delete", source_path, f"{node}:{dest_path}"], 
                                check=True, capture_output=True, text=True)
        logger.debug(f"Rsync result: {result.stdout}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Rsync error: {e}")
        logger.error(f"Command output: {e.output}")

def csync_full_sync_threaded(csync_opts, includes, nodes):
    global last_full_sync
    if shutdown_flag:
        return
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
        list(executor.map(lambda node: update_node_threaded(node, csync_opts), nodes))

    last_full_sync = time.time()
    logger.info("  Done")

def process_changes_threaded(csync_opts, includes, nodes, csync_files):
    if shutdown_flag:
        return
    csync_server_wait()

    if use_rsync and len(csync_files) >= rsync_threshold:
        logger.info(f"Using rsync for large batch: {len(csync_files)} files")
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(nodes)) as executor:
            list(executor.map(lambda args: rsync_update_threaded(*args), 
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
            list(executor.map(lambda node: update_node_threaded(node, csync_opts), nodes))

    logger.info("  Done")

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
        initialize_environment()
        if args.mode == 'async':
            asyncio.run(run_async(csync_opts))
        else:
            run_threaded(csync_opts)
    except Exception as e:
        logger.critical(f"Unhandled exception: {e}")
        logger.debug(traceback.format_exc())
        sys.exit(1)
```

# Inotify Csync Optimized Script Documentation

## Overview

This Python script provides an advanced solution for file synchronization across multiple servers using csync2 and inotify. It improves upon previous versions by implementing both asynchronous and threaded modes of operation, enhanced error handling, and more detailed logging options.

## Features

- Dual-mode operation: Asynchronous (using asyncio) and Threaded
- Multi-threaded file event monitoring using pyinotify
- Hybrid approach using rsync for large batches of files (optional)
- Configurable thresholds for batch processing and rsync usage
- Parallel updates for multiple nodes
- Efficient queuing system
- Periodic full syncs and queue resets to ensure consistency
- Detailed logging with debug option
- Improved error handling and robustness

## Requirements

- Python 3.7+. EL9 OSes default to Python 3.9 already, while EL8 default to Python 3.6 so need updating to at least Python 3.8.
- pyinotify
- csync2
- rsync (optional, for large batch processing)

For EL8 (AlmaLinux 8, Rocky Linux 8, etc.), to update from Python 3.6 to 3.8 defaults.

for Centmin Mod 140.00beta01

```
cmupdate
/usr/local/src/centminmod/addons/python_switch_el8.sh --python38
```
```
cmupdate
No local changes to save
Already up to date.
No local changes to save
Already up to date.

/usr/local/src/centminmod/addons/python_switch_el8.sh --python38

Detected AlmaLinux 8
Switching to Python 3.8...
Looking in links: /tmp/tmpijtzg56p
Requirement already up-to-date: setuptools in /usr/lib/python3.8/site-packages (41.6.0)
Requirement already up-to-date: pip in /usr/local/lib/python3.8/site-packages (24.1.2)
Requirement already satisfied: pip in /usr/local/lib/python3.8/site-packages (24.1.2)
Python version switched successfully.

Python alternatives set
python3                 manual  /usr/bin/python3.8
unversioned-python      manual  /usr/bin/python3.8
python                  manual  /usr/bin/unversioned-python
pip                     manual  /usr/local/bin/pip3.8
pip3                    manual  /usr/local/bin/pip3.8

python3 --version
Python 3.8.17
python --version
Python 3.8.17
pip --version
pip 24.1.2 from /usr/local/lib/python3.8/site-packages/pip (python 3.8)
```

Or non-Centmin Mod

```
sudo dnf -y module reset python38
sudo dnf -y module enable python38
sudo dnf -y install python38 python3-pip

# Set the default python3 to Python 3.8
sudo alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 2
sudo alternatives --set python3 /usr/bin/python3.8

# Set the unversioned Python to Python 3.8
sudo alternatives --install /usr/bin/unversioned-python unversioned-python /usr/bin/python3.8 2
sudo alternatives --set unversioned-python /usr/bin/python3.8

# Set pip for Python 3.8
sudo rm -f /usr/local/bin/pip /usr/local/bin/pip3
python3.8 -m ensurepip --upgrade 2>/dev/null
python3.8 -m pip install --upgrade pip 2>/dev/null

sudo alternatives --install /usr/bin/pip pip /usr/local/bin/pip3.8 1
sudo alternatives --install /usr/bin/pip3 pip3 /usr/local/bin/pip3.8 1
sudo alternatives --set pip /usr/local/bin/pip3.8
sudo alternatives --set pip3 /usr/local/bin/pip3.8
```

## Installation

1. Install the required Python package:
   ```
   pip install pyinotify
   ```

2. Ensure csync2 is installed on your system. Install rsync if you plan to use it for large batches.

3. Save the script as `inotify_csync_asyncio.py` and make it executable:
   ```
   chmod +x inotify_csync_asyncio.py
   ```

## Configuration

The script uses several configuration parameters that can be adjusted through command-line arguments.

### Command-line Arguments

- `--config`: Path to the csync2 configuration file (default: "/etc/csync2/csync2.cfg")
- `--check-interval`: Interval between queue checks in seconds (default: 0.5)
- `--full-sync-interval`: Interval between full syncs in seconds (default: 3600)
- `--num-lines-until-reset`: Number of lines processed before resetting the queue (default: 200000)
- `--num-batched-changes-threshold`: Threshold for batch processing (default: 15000)
- `--rsync-threshold`: Threshold for using rsync instead of csync2 (default: 5000)
- `--parallel-updates`: Enable parallel updates (default: 1)
- `--max-wait-time`: Maximum wait time before processing queue in seconds (default: 10)
- `-m, --mode`: Execution mode, either 'async' or 'thread' (default: 'async')
- `--disable-rsync`: Disable the use of rsync for large batches
- `--debug`: Enable debug logging

## Usage

Set up script at `/usr/local/bin/inotify_csync.py` with executable permissions and run the script with the desired options:

```
/usr/local/bin/inotify_csync.py -N hostname [additional csync2 options]
```

Replace `hostname` with the name of the current host as specified in the csync2 configuration file.

Example with additional options:

```
/usr/local/bin/inotify_csync.py -N host1 --mode thread --debug --disable-rsync
```

Setup as systemd service

On `host1`


`/etc/systemd/system/inotify_csync.service`

```
[Unit]
Description=Inotify Csync2 Sync Service
After=network.target

[Service]
Type=simple
# Pre-start script to kill any running csync2 processes
ExecStartPre=/bin/bash -c 'pgrep -f csync2 && killall csync2 || true'
# Start the csync2 service
ExecStart=/usr/local/bin/inotify_csync.py -N host1
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/home/csync2-inotify

[Install]
WantedBy=multi-user.target
```

On `host2`


`/etc/systemd/system/inotify_csync.service`

```
[Unit]
Description=Inotify Csync2 Sync Service
After=network.target

[Service]
Type=simple
# Pre-start script to kill any running csync2 processes
ExecStartPre=/bin/bash -c 'pgrep -f csync2 && killall csync2 || true'
# Start the csync2 service
ExecStart=/usr/local/bin/inotify_csync.py -N host2
Restart=on-failure
RestartSec=5
User=root
WorkingDirectory=/home/csync2-inotify

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable inotify_csync.service
sudo systemctl start inotify_csync.service
sudo journalctl -u inotify_csync.service --no-pager | tail -25
sudo systemctl status inotify_csync.service --no-pager -l
```

## How It Works

1. **Initialization**:
   - The script parses command-line arguments and the csync2 configuration file.
   - It sets up logging based on the debug flag.
   - A pyinotify ThreadedNotifier is set up to monitor file system events on the specified include paths.
   - A csync2 server is started in the background.

2. **Event Handling**:
   - The ChangeEventHandler class processes various file system events and adds the affected file paths to a queue.

3. **Queue Processing**:
   - In threaded mode, the `process_queue_thread` function continuously checks the queue for new events.
   - In async mode, an equivalent asynchronous function performs this task.
   - Events are batched up to the specified threshold or until the max wait time is reached.
   - For small batches, it uses csync2 to process the changes.
   - For large batches (exceeding the rsync_threshold), it optionally switches to using rsync for faster processing.

4. **Synchronization**:
   - The script performs incremental syncs based on the queued events.
   - It also conducts periodic full syncs and queue resets to ensure consistency across all nodes.

5. **Parallel Updates**:
   - When updating multiple nodes, the script can perform updates in parallel to improve performance.

## Logging and Debugging

- The script uses Python's logging module to provide informational and debug output.
- Use the `--debug` flag to enable detailed debug logging.
- Log messages include timestamps and log levels for easy troubleshooting.

## Error Handling

- The script includes comprehensive error handling for various operations including file operations, subprocess calls, and network operations.
- Errors are logged with appropriate context to aid in troubleshooting.

## Performance Tuning

- Choose between async and threaded modes based on your system's characteristics and performance needs.
- Adjust the `check_interval`, `full_sync_interval`, and `max_wait_time` parameters to balance between responsiveness and system load.
- Modify the `num_batched_changes_threshold` and `rsync_threshold` based on your typical file change patterns and network capabilities.
- Enable or disable rsync usage for large batches depending on your network topology and server capabilities.

## Limitations and Considerations

- The script requires appropriate permissions to access all monitored directories and perform system-wide changes.
- Large numbers of simultaneous file changes may still cause delays in synchronization.
- Network issues between nodes can affect the synchronization process.
- When using rsync, ensure that SSH key-based authentication is set up between nodes for passwordless operation.

## Troubleshooting

- Check the log output for error messages and warnings.
- Use the `--debug` flag to get more detailed information about the script's operation.
- Verify that the csync2 configuration file is correctly set up and accessible.
- Ensure that all specified include paths exist and are accessible.
- Check network connectivity between nodes if synchronization is failing.

## Conclusion

This optimized inotify_csync script provides a robust, flexible, and efficient solution for keeping multiple servers in sync using csync2 and inotify. With its dual-mode operation, enhanced error handling, and detailed logging options, it offers improved performance, reliability, and ease of troubleshooting compared to previous implementations.
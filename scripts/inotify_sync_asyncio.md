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
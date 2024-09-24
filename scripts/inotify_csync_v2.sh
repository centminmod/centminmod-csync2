#!/bin/bash

# Watch csync directories and sync changes via csync2

# --- SETTINGS ---

file_events="move,delete,attrib,create,close_write,modify"
queue_file=/home/csync2-inotify/tmp/inotify_queue.log
csync_log=/home/csync2-inotify/tmp/csync_server.log
mkdir -p /home/csync2-inotify/tmp

check_interval=0.5
full_sync_interval=$((60*60))
num_lines_until_reset=200000
num_batched_changes_threshold=15000
parallel_updates=1
early_threshold_check="no"

cfg_path=/etc/csync2
cfg_file=csync2.cfg

debug_mode=0
csync_opts=()
this_node=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -debug)
            debug_mode=1
            shift
            ;;
        -N)
            if [[ -n $2 ]]; then
                this_node=$2
                csync_opts+=("$1" "$2")
                shift 2
            else
                echo "Error: -N requires a hostname argument"
                exit 1
            fi
            ;;
        *)
            csync_opts+=("$1")
            shift
            ;;
    esac
done

# Function for debug logging
debug_log() {
    if [[ $debug_mode -eq 1 ]]; then
        echo "DEBUG: $*"
    fi
}

# --- VERSION ---

echo "CSync Controller"
echo "Version 18 Sep 2024"
echo
echo "Passed options: ${csync_opts[*]}"
echo
echo "* SETTINGS"
echo "  debug_mode                    = ${debug_mode}"
echo "  check_interval                = ${check_interval}s"
echo "  full_sync_interval            = ${full_sync_interval}s"
echo "  num_lines_until_reset         = $num_lines_until_reset"
echo "  num_batched_changes_threshold = $num_batched_changes_threshold"
echo "  parallel_updates              = $parallel_updates"

# Check if hostname is specified
if [[ -z $this_node ]]; then
    echo "*** WARNING: No hostname specified ***"
    sleep 2
else
    echo "Hostname: $this_node"
fi

# --- CSYNC SERVER ---

# Set server options
server_opts=(-N "$this_node")

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
    for excluded in "${excludes[@]}"
    do
        if [[ $file == $excluded* ]]
        then
            continue 2
        fi
    done

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

    csync_server_wait

    if (( parallel_updates ))
    then
        echo "  Checking all files"
        csync2 "${csync_opts[@]}" -cr "/"

        update_pids=()
        for node in "${nodes[@]}"
        do
            echo "  Updating $node"
            csync2 "${csync_opts[@]}" -ub -P "$node" &
            update_pids+=($!)
        done
        wait "${update_pids[@]}"
    else
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

    truncate -s 0 $queue_file
    queue_line_pos=1

    csync_full_sync

    truncate -s 0 $csync_log
}

# --- QUEUE PROCESSING ---

csync_full_sync

queue_line_pos=1
last_full_sync=$(date +%s)
while true
do
    sleep $check_interval

    mapfile -t file_list < <(tail --lines=+$queue_line_pos $queue_file)

    if [[ ${#file_list[@]} -eq 0 ]]
    then
        if [[ $queue_line_pos -ge $num_lines_until_reset ]]
        then
            reset_queue
        elif (( full_sync_interval && ($(date +%s) - last_full_sync) > full_sync_interval ))
        then
            csync_full_sync
        fi
        continue
    fi

    echo
    echo "* PROCESSING QUEUE (line $queue_line_pos)"

    ((queue_line_pos+=${#file_list[@]}))

    debug_log "--- Debug Info ---"
    debug_log "Queue position: $queue_line_pos"
    debug_log "Threshold: $num_batched_changes_threshold"
    debug_log "Number of files in file_list: ${#file_list[@]}"

    declare -A seen_files
    csync_files=()

    if [[ "$early_threshold_check" == "yes" ]]; then
        for file in "${file_list[@]}"; do
            debug_log "Processing file: $file"
            if [[ -z ${seen_files[$file]} ]]; then
                debug_log "New file detected: $file"
                seen_files[$file]=1
                csync_files+=("$file")
                if [[ ${#csync_files[@]} -ge $num_batched_changes_threshold ]]; then
                    echo "* LARGE BATCH (${#csync_files[@]} files) - Early check"
                    csync_full_sync
                    continue 2
                fi
            else
                debug_log "Duplicate file: $file"
            fi
        done
    else
        for file in "${file_list[@]}"; do
            debug_log "Processing file: $file"
            if [[ -z ${seen_files[$file]} ]]; then
                debug_log "New file detected: $file"
                seen_files[$file]=1
                csync_files+=("$file")
            else
                debug_log "Duplicate file: $file"
            fi
        done

        debug_log "Number of files after deduplication: ${#csync_files[@]}"

        if [[ ${#csync_files[@]} -ge $num_batched_changes_threshold ]]; then
            echo "* LARGE BATCH (${#csync_files[@]} files)"
            csync_full_sync
            continue
        fi
    fi

    if [[ ${#csync_files[@]} -gt 0 ]]; then
        debug_log "Processing batch of ${#csync_files[@]} files"
        csync_server_wait

        echo "  Checking ${#csync_files[@]} files"
        csync2 "${csync_opts[@]}" -cr "${csync_files[@]}"

        if (( parallel_updates )); then
            update_pids=()
            for node in "${nodes[@]}"; do
                echo "  Updating $node"
                csync2 "${csync_opts[@]}" -ub -P "$node" &
                update_pids+=($!)
            done
            wait "${update_pids[@]}"
        else
            echo "  Updating peers sequentially"
            csync2 "${csync_opts[@]}" -u
        fi

        echo "  Done"
    fi
    debug_log "--- End of Loop ---"
done
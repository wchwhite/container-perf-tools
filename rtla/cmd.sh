#!/bin/bash

# env vars:
#   DURATION (default: no timer for osnoise and timerlat, the default for hwnoise is 24h)
#   DISABLE_CPU_BALANCE (default "n", choices y/n)
#   PRIO (RT priority, default "". If no option passed, uses rtla defaults. Choices [policy:priority]. fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000)
#   RTLA_TOP (default "n", choices y/n, ignored for hwnoise. Defaults to build a histogram when n)
#   RTLA_MODE (default "error", choices "timerlat", "hwnoise", or "osnoise". If none are given, we error.)
#   STORAGE_MODE (default "n", choices y/n, changes RTLA_MODE to hist.)
#   PAUSE (default: y, pauses after run. choices y/n)
#   DELAY (default 0, specify how many seconds to delay before test start)
#   AA_THRESHOLD (default 100, sets automatic trace mode stopping the session if latency in us is hit. A value of 0 disables this feature)
#   THRESHOLD (default 0, if set, stops trace if the thread latency is higher than the argument in us. This overrides the -a flag and its value if it is not 0)
#   EVENTS (Allows specifying multiple trace events. Default is blank. This should be provided as a comma separated list.)
#   CHECK_US (Allows RTLA to also check for userspace induced latency. Options are 'y' or 'n'. Default is 'n'.)
#   CUSTOM_OPTIONS (Allows specifying custom options. Default is blank. Provide as a space separated list of options.)

if [[ "${help:-}" == "y" ]]; then
    echo "Usage: ./scriptname.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  help=y               Show this help message"
    echo "  DURATION=value       Set the duration. Default is no timer for osnoise and timerlat, the default for hwnoise is 24h."
    echo "  DISABLE_CPU_BALANCE=value Set whether to disable CPU balance. Default is 'n'. Choices are 'y' or 'n'."
    echo "  PRIO=value           Set RT priority. Default is ''."
    echo "                       Choices are [policy:priority]. Examples: fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000."
    echo "  RTLA_TOP=value       Default is 'n'. Choices are 'y' or 'n'."
    echo "  RTLA_MODE=value      Set mode. Default is 'error'. Choices are 'timerlat', 'hwnoise', or 'osnoise'."
    echo "  STORAGE_MODE=value   Set storage mode. Default is 'n'. Choices are 'y' or 'n'."
    echo "  PAUSE=value          Pause after run. Default is 'y'. Choices are 'y' or 'n'."
    echo "  DELAY=value          Specify how many seconds to DELAY before test start. Default is 0."
    echo "  AA_THRESHOLD=value   Sets automatic trace mode stopping the session if latency in us is hit. Default is 100."
    echo "  THRESHOLD=value      If set, stops trace if the thread latency is higher than the value in us. Default is 0."
    echo "  EVENTS=value         Allows specifying multiple trace events. Default is blank. This should be provided as a comma separated list."
    echo "  CHECK_US=value       Allows RTLA to also check for userspace induced latency. Options are 'y' or 'n'. Default is 'n'."
    echo "  CUSTOM_OPTIONS=value Allows specifying custom options. Default is blank. Provide as a space separated list of options."
    exit 0
fi


source common-libs/functions.sh

# Initialize default variables
RTLA_MODE=${RTLA_MODE:-"error"}
STORAGE_MODE=${STORAGE_MODE:-n}
PAUSE=${PAUSE:-"y"}
DISABLE_CPU_BALANCE=${DISABLE_CPU_BALANCE:-n}
RTLA_TOP=${RTLA_TOP:-n}
DELAY=${DELAY:-0}
DURATION=${DURATION:-""}
manual=${manual:-n}
AA_THRESHOLD=${AA_THRESHOLD:-100}
THRESHOLD=${THRESHOLD:-0}
EVENTS=${EVENTS:-""}
CHECK_US=${CHECK_US:-n}
CUSTOM_OPTIONS=${CUSTOM_OPTIONS:-""}

# convert the custom_options string into an array
original_ifs="$IFS" #for resetting IFS
IFS=' ' read -r -a custom_options_arr <<< "$CUSTOM_OPTIONS"
IFS=$original_ifs
IFS=',' read -r -a events_array <<< $EVENTS
IFS=$original_ifs

rtla_results="/root/rtla_results.txt"

mode="hist"
run_mode="hist"
if [[ "$RTLA_TOP" == "y" ]]; then
    mode="top"
    run_mode="top"
fi

# hwnoise does not support either hist or top, so set this to blank so we can use generic logic.
if [[ "$RTLA_MODE" == "hwnoise" ]]; then
    mode=""
    run_mode=top
fi

function sigfunc() {
    if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
        enable_balance
    fi
    exit 0
}

function create_file() {
    log_dir="/var/log/app"

    # List of required directories
    required_dirs=("timerlat/hist" "timerlat/top" "osnoise/hist" "osnoise/top" "hwnoise/hist" "hwnoise/top")

    # Check if directories exist, if not, create them
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$log_dir/$dir" ]; then
            mkdir -p "$log_dir/$dir"
        fi
    done

    timestamp=$(date +%Y%m%d%H%M%S)

    # Get the latest file number
    last_file_number=$(ls $log_dir/"$RTLA_MODE"/"$run_mode" | grep $RTLA_MODE | grep $run_mode | sort -n | tail -n 1 | cut -c 1-1)

    # If no files found create the first file
    if [ -z "$last_file_number" ]; then
        file_path="$log_dir/"$RTLA_MODE"/"$run_mode"/1_"$RTLA_MODE"_"$run_mode"-$timestamp.log"
    else
        # If files found, increment the last file number and create a new file
        new_file_number=$((last_file_number + 1))
        file_path="$log_dir/"$RTLA_MODE"/"$run_mode"/${new_file_number}_"$RTLA_MODE"_"$run_mode"-$timestamp.log"
    fi

    touch "$file_path"
    echo "$file_path"
}

# No storage option for rtla top mode
if [[ "$STORAGE_MODE" == "y" ]]; then
    path=$(create_file)
    echo "Storing log files at $path" | tee -a $path
    storage() { tee -a "$path"; }
else
    echo "Persistent storage not used"
    
    storage() { cat;  }  # Do nothing and return
fi

if [[ -n $PRIO ]]; then
    if [[ $PRIO =~ ^[for]:[0-9]+$ || $PRIO =~ ^d:[0-9]+(us|ms|s):[0-9]+(us|ms|s)$ ]]; then
        echo "PRIORITY was provided: $PRIO" | storage
    else
        echo "WARNING! PRIO is not valid. Setting PRIO to default values." | storage
        echo "To properly set PRIORITY, please use the following:" | storage
        echo "Choices [policy:priority]. fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000" | storage
        PRIO=""
    fi
fi
#I need to add a custom param option to feed in a string of extra options




# Check if events string is not blank
# Validate each element in the array
for e in "${events_arr[@]}"; do
    # Validate each event against the desired regex pattern
    if ! echo "$e" | grep -Pq "^[a-zA-Z0-9_]+(:[a-zA-Z0-9_]+)?$"; then
        echo "Invalid event format: $e. It must be one word or two sets of words with a colon in between. Each word can include underscore '_' but no spaces."
        exit 1
    fi
done



echo "############# dumping env ###########" | storage
env | storage
echo "#####################################" | storage

echo " " | storage
echo "########## container info ###########" | storage
echo "/proc/cmdline:" | storage
cat /proc/cmdline | storage
echo "#####################################" | storage

echo "**** uid: $UID ****" | storage

release=$(cat /etc/os-release | sed -n -r 's/VERSION_ID="(.).*/\1/p')

# Check the mode
case "$RTLA_MODE" in
  "timerlat"|"hwnoise"|"osnoise")
    echo "Operating in $RTLA_MODE mode." | storage
    ;;
  *)
    echo "Error: Invalid mode. Please set RTLA_MODE to 'timerlat', 'hwnoise', or 'osnoise'." | storage
    exit 1
    ;;
esac

for cmd in rtla; do
    command -v $cmd >/dev/null 2>&1 || { echo >&2 "$cmd required but not installed. Aborting" | storage; exit 1; }
done

cpulist=`get_allowed_cpuset`
echo "allowed cpu list: ${cpulist}" | storage

uname=`uname -nr`
echo "$uname"

cpulist_stress=`convert_number_range ${cpulist} | tr , '\n' | sort -n | uniq`

declare -a cpus
cpus=(${cpulist_stress})

if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
    disable_balance
fi

trap sigfunc TERM INT SIGUSR1

mode="hist"
if [[ "$RTLA_TOP" == "y" ]]; then
    mode="top"
fi

# hwnoise does not support either hist or top, so set this to blank so we can use generic logic.
if [[ "$RTLA_MODE" == "hwnoise" ]]; then
    mode=""
fi

# Set the generic shared components of the tools
command_args=("rtla" "$RTLA_MODE" "$mode" "-c" "$cpulist")

# Set the generic shared options
if [[ -z "${DURATION}" ]]; then
    echo "running rtla with out timeout" | storage
else
    command_args=("${command_args[@]}" "-d" "${DURATION}")
fi

if [[ -n "${PRIO}" ]]; then
    command_args=("${command_args[@]}" "-P" "${PRIO}")
else
    echo "Running with default priority." | storage
fi

if [[ "${CHECK_US}" == "y" ]]; then
    command_args=("${command_args[@]}" "-u")
fi

if [[ -n "$CUSTOM_OPTIONS" ]]; then
    for opt in "${custom_options_arr[@]}"; do
        command_args=("${command_args[@]}" "$opt")
    done
fi

if [[ -n "$EVENTS" ]]; then
    for e in "${events_array[@]}"; do
        command_args=("${command_args[@]}" "-e" "$e")
    done
fi

if [[ "${THRESHOLD}" -ne 0 ]]; then
    command_args=("${command_args[@]}" "-T" "$THRESHOLD")
elif [[ "${AA_THRESHOLD}" -eq 0 && "${THRESHOLD}" -eq 0 ]]; then
    echo "Not using --auto-analysis feature"
else
    command_args=("${command_args[@]}" "-a" "$AA_THRESHOLD")
fi


echo "running cmd: "${command_args[@]}"" | storage
if [[ "${manual}" == "y" ]]; then
    echo "Entering into manual intervention mode" | storage
    sleep infinity
fi

if [[ "${DELAY}" != "0" ]]; then
    echo "sleep ${DELAY} before test" | storage
    sleep ${DELAY}
fi

# Due to some wierdness in the hist and top outputs, the 
# storage() function swallows this output when STORAGE_MODE=n
# Setting this so that the rtla output is not swallowed.
if [[ "$STORAGE_MODE" == "y" ]]; then
    "${command_args[@]}" | storage
else 
    "${command_args[@]}"
fi


if [[ "$PAUSE" == "y" ]]; then
    sleep infinity
fi 

if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
    enable_balance
fi

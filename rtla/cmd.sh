#!/bin/bash

# env vars:
#   DURATION (default: no timer for osnoise and timerlat, the default for hwnoise is 24h)
#   DISABLE_CPU_BALANCE (default "n", choices y/n)
#   HOUSEKEEPING_PER_NUMA (default 0, set the number of housekeeping cores per NUMA node. Overrides measurement configs.)
#   ALLCPUSET (default "n", choices y/n, On some machines (like VMs, this value returns 0 for cpuset. This option allows you to use all cores in this case.))
#   PRIO (RT priority, default "". If no option passed, uses rtla defaults. Choices [policy:priority]. fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000)
#   RTLA_TOP (default "n", choices y/n, ignored for hwnoise. Defaults to build a histogram when n)
#   COMMAND (default "error", choices "timerlat", "hwnoise", or "osnoise". If none are given, we error.)
#   STORAGE_MODE (default "n", choices y/n, if y, stores the results in a file. Must mount storage)
#   PAUSE (default: y, pauses after run. choices y/n)
#   DELAY (default 0, specify how many seconds to delay before test start)
#   AA_THRESHOLD (default 100, sets automatic trace mode stopping the session if latency in us is hit. A value of 0 disables this feature)
#   MAX_LATENCY (default 0, if set, stops trace if the thread latency is higher than the argument in us. This overrides the -a flag and its value if it is not 0)
#   EVENTS (Allows specifying multiple trace events. Default is blank. This should be provided as a comma separated list.)
#   CHECK_US (Allows RTLA to also check for userspace induced latency. Options are 'y' or 'n'. Default is 'n'.)
#   EXTRA_ARGS (Allows specifying custom options. Default is blank. Provide as a space separated list of options.)

source common-libs/functions.sh

function sigfunc() {
    if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
        enable_balance
    fi
    exit 0
}

function storage() { 
    tee -a "$path"; 
}

if [[ "${help:-}" == "y" ]]; then
    echo "Usage: ./scriptname.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  help=y               Show this help message"
    echo "  DURATION=value       Set the duration. Default is no timer for osnoise and timerlat, the default for hwnoise is 24h."
    echo "  DISABLE_CPU_BALANCE=value Set whether to disable CPU balance. Default is 'n'. Choices are 'y' or 'n'."
    echo "  HOUSEKEEPING_PER_NUMA=value Set the number of housekeeping cores per NUMA node. Default is 0. Overrides measurement configs."
    echo "  ALLCPUSET=value      Use when no CPUSET is defined to tell rtla to use all cores as measurement. Default is 'n'. Choices are 'y' or 'n'."
    echo "  PRIO=value           Set RT priority. Default is ''."
    echo "                       Choices are [policy:priority]. Examples: fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000."
    echo "  RTLA_TOP=value       Default is 'n'. Choices are 'y' or 'n'."
    echo "  COMMAND=value      Set mode. Default is 'error'. Choices are 'timerlat', 'hwnoise', or 'osnoise'."
    echo "  STORAGE_MODE=value   Set storage mode. Default is 'n'. Choices are 'y' or 'n'. Mount a volume at /var/log/app to persist logs!"
    echo "  PAUSE=value          Pause after run. Default is 'y'. Choices are 'y' or 'n'."
    echo "  DELAY=value          Specify how many seconds to DELAY before test start. Default is 0."
    echo "  AA_THRESHOLD=value   Sets automatic trace mode stopping the session if latency in us is hit. Default is 20."
    echo "  MAX_LATENCY=value      If set, stops trace if the thread latency is higher than the value in us. Default is 0."
    echo "  EVENTS=value         Allows specifying multiple trace events. Default is blank. This should be provided as a comma separated list."
    echo "  CHECK_US=value       Allows RTLA to also check for userspace induced latency. Options are 'y' or 'n'. Default is 'n'."
    echo "  EXTRA_ARGS=value Allows specifying custom options. Default is blank. Provide as a space separated list of options."
    exit 0
fi

# Initialize default variables
COMMAND=${COMMAND:-"error"}
STORAGE_MODE=${STORAGE_MODE:-n}
PAUSE=${PAUSE:-"y"}
DISABLE_CPU_BALANCE=${DISABLE_CPU_BALANCE:-n}
HOUSEKEEPING_PER_NUMA=${HOUSEKEEPING_PER_NUMA:-0}
ALLCPUSET=${ALLCPUSET:-n}
RTLA_TOP=${RTLA_TOP:-n}
DELAY=${DELAY:-0}
DURATION=${DURATION:-"24h"}
manual=${manual:-n}
AA_THRESHOLD=${AA_THRESHOLD:-20}
MAX_LATENCY=${MAX_LATENCY:-0}
EVENTS=${EVENTS:-""}
CHECK_US=${CHECK_US:-n}
EXTRA_ARGS=${EXTRA_ARGS:-""}


# Check if the command is installed
if ! command -v rtla &> /dev/null; then
    echo "rtla is not installed. Installing now..."
    sudo dnf install rtla -y
else
    echo "rtla is already installed."
fi

# convert the custom_options string into an array
original_ifs="$IFS" #for resetting IFS
IFS=' ' read -r -a custom_options_arr <<< "$EXTRA_ARGS"
IFS=$original_ifs
IFS=',' read -r -a events_array <<< $EVENTS
IFS=$original_ifs

rtla_results="/root/rtla_results.txt"

mode="hist"
if [[ "$RTLA_TOP" == "y" ]]; then
    mode="top"
fi

# hwnoise does not support either hist or top, so set this to blank so we can use generic logic.
if [[ "$COMMAND" == "hwnoise" ]]; then
    mode=""
fi
required_dirs=("timerlat/hist" "timerlat/top" "osnoise/hist" "osnoise/top" "hwnoise/default" )
path=$(create_file $COMMAND $mode $required_dirs)
echo "Storing log files at $path" | storage
if ["$STORAGE_MODE" == "y"]; then
    echo "INFO: Mount a volume at /var/log/app to persist logs!!!" | storage
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

# Check if events string is not blank
# Validate each element in the array
for e in "${events_arr[@]}"; do
    # Validate each event against the desired regex pattern
    if ! echo "$e" | grep -Pq "^[a-zA-Z0-9_]+(:[a-zA-Z0-9_]+)?$"; then
        echo "Invalid event format: $e. It must be one word or two sets of words with a colon in between. Each word can include underscore '_' but no spaces."
        exit 1
    fi
done


uname=`uname -nr` # get the kernel version
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
case "$COMMAND" in
  "timerlat"|"hwnoise"|"osnoise")
    echo "Operating in $COMMAND mode." | storage
    ;;
  *)
    echo "Error: Invalid mode. Please set COMMAND to 'timerlat', 'hwnoise', or 'osnoise'." | storage
    exit 1
    ;;
esac

cpuset=`get_allowed_cpuset`
echo "cpuset: $cpuset" | storage

## ALLCPUSET handles a bug in rhel9 (and possible others) where cpuset is 0 when no cpuset is defined.
## Deprecate this once the bug is fixed.
if [[ "$cpuset" == "0" && "$ALLCPUSET" == "y" ]]; then
    echo "present cpus: " | storage
    work_cores=`get_host_cores`
    echo "Info: No cpu-set used, using all CPUs" | storage
    echo "WARNING: If trying to run on CPU0, make sure ALLCPUSET=n (Default behavior)" | storage
else
    if [[ "$cpuset" -eq 0 ]]; then
        echo "Warning: cpuset is bound to CPU0. If you are trying to use all cpus add '-e ALLCPUSET=y' to your run command." | storage
    fi
    if [[ "$ALLCPUSET" == "y" ]]; then
        echo "Warning: ALLCPUSET is set to y but cpuset was provided. ALLCPUSET will be ignored in favor of the provided cpuset." | storage
    fi
    work_cores=$cpuset
fi


if [[ $HOUSEKEEPING_PER_NUMA -gt 0 ]]; then
    populate_numa_info $cpuset
    echo "Housekeeping core: $housekeeping_cores"
    echo "Work cores: $work_cores"
fi

echo "The worker cpus being used are: $work_cores" | storage

if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
    disable_balance
fi

trap sigfunc TERM INT SIGUSR1

mode="hist"
if [[ "$RTLA_TOP" == "y" ]]; then
    mode="top"
fi

# hwnoise does not currently does not support hist mode
if [[ "$COMMAND" == "hwnoise" ]]; then
    mode=""
fi

# Set the generic shared components of the tools
command_args=("rtla" "$COMMAND" "$mode" "-c" "$work_cores")

if [[ $HOUSEKEEPING_PER_NUMA -gt 0 ]]; then
    if [[ "$cpuset" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Detected that we are only running on one CPU. Not setting -H as evrything runs on the same CPU anyways." | storage
    else 
        command_args=("${command_args[@]}" "-H" "${housekeeping_cores}")
    fi
    
fi

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

if [[ -n "$EXTRA_ARGS" ]]; then
    for opt in "${custom_options_arr[@]}"; do
        command_args=("${command_args[@]}" "$opt")
    done
fi

if [[ -n "$EVENTS" ]]; then
    for e in "${events_array[@]}"; do
        command_args=("${command_args[@]}" "-e" "$e")
    done
fi

if [[ "${MAX_LATENCY}" -ne 0 ]]; then
    command_args=("${command_args[@]}" "-T" "$MAX_LATENCY")
elif [[ "${AA_THRESHOLD}" -eq 0 && "${MAX_LATENCY}" -eq 0 ]]; then
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

"${command_args[@]}" | storage

if [ -f "/root/${COMMAND}_trace.txt" ]; then
    cp "/root/${COMMAND}_trace.txt" "${path}_${COMMAND}_trace.txt"
    echo "Trace data copied to: ${path}_${COMMAND}_trace.txt" | storage
    echo "Either mount storage or set PAUSE=y to retrieve it" | storage
else
    echo "/root/${COMMAND}_trace.txt does not exist!" | storage
    echo "No trace data was generated with the ${COMMAND} option." | storage
fi

if [[ "$PAUSE" == "y" ]]; then
    echo "DONE: If a trace was collected you can retrieve it with:" | storage
    echo "oc cp ${COMMAND}:/root/${COMMAND}_trace.txt ${COMMAND}_trace.txt" | storage
    echo "Pausing after run" | storage
    sleep infinity
fi 

if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
    enable_balance
fi

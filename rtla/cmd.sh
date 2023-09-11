#!/bin/bash

# env vars:
#   DURATION (default: no timer for osnoise and timerlat, the default for hwnoise is 24h)
#   DISABLE_CPU_BALANCE (default "n", choices y/n)
#   PRIO (RT priority, default "". If no option passed, uses rtla defaults. Choices [policy:priority]. fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000)
#   rtla_top (default "n", choices y/n, ignored for hwnoise. Defaults to build a histogram when n)
#   rlta_mode (default "error", choices "timerlat", "hwnoise", or "osnoise". If none are given, we error.)
#   storage_mode (default "n", choices y/n, changes rtla_mode to hist.)
#   pause (default: y, pauses after run. choices y/n)
#   delay (default 0, specify how many seconds to delay before test start)
#   aa_threshold (default 100, sets automatic trace mode stopping the session if latency in us is hit. A value of 0 disables this feature)
#   threshold (default 0, if set, stops trace if the thread latency is higher than the argument in us. This overrides the -a flag and its value if it is not 0)
#   events (optional, defaults to blank, allows specifying multiple trace events)

if [[ "${help:-}" == "y" ]]; then
    echo "Usage: ./scriptname.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  help=y               Show this help message"
    echo "  DURATION=value       Set the duration. Default is no timer for osnoise and timerlat, the default for hwnoise is 24h."
    echo "  DISABLE_CPU_BALANCE=value Set whether to disable CPU balance. Default is 'n'. Choices are 'y' or 'n'."
    echo "  PRIO=value           Set RT priority. Default is ''."
    echo "                       Choices are [policy:priority]. Examples: fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000."
    echo "  rtla_top=value       Default is 'n'. Choices are 'y' or 'n'."
    echo "  rtla_mode=value      Set mode. Default is 'error'. Choices are 'timerlat', 'hwnoise', or 'osnoise'."
    echo "  storage_mode=value   Set storage mode. Default is 'n'. Choices are 'y' or 'n'."
    echo "  pause=value          Pause after run. Default is 'y'. Choices are 'y' or 'n'."
    echo "  delay=value          Specify how many seconds to delay before test start. Default is 0."
    echo "  aa_threshold=value   Sets automatic trace mode stopping the session if latency in us is hit. Default is 100."
    echo "  threshold=value      If set, stops trace if the thread latency is higher than the value in us. Default is 0."
    echo "  events=value         Allows specifying multiple trace events. Default is blank."
    echo "  custom_options=value Allows specifying custom options. Default is blank."
    exit 0
fi


source common-libs/functions.sh

# Initialize default variables
rtla_mode=${rtla_mode:-"error"}
storage_mode=${storage_mode:-n}
pause=${pause:-"y"}
DISABLE_CPU_BALANCE=${DISABLE_CPU_BALANCE:-n}
rtla_top=${rtla_top:-n}
delay=${delay:-0}
DURATION=${DURATION:-""}
manual=${manual:-n}
aa_threshold=${aa_threshold:-100}
threshold=${threshold:-0}
events=${events:-""}
custom_options=${custom_options:-""}

# convert the custom_options string into an array
IFS=' ' read -r -a custom_options_arr <<< "$custom_options"

rtla_results="/root/rtla_results.txt"

mode="hist"
run_mode="hist"
if [[ "$rtla_top" == "y" ]]; then
    mode="top"
    run_mode="top"
fi

# hwnoise does not support either hist or top, so set this to blank so we can use generic logic.
if [[ "$rtla_mode" == "hwnoise" ]]; then
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
    last_file_number=$(ls $log_dir/"$rtla_mode"/"$run_mode" | grep $rtla_mode | grep $run_mode | sort -n | tail -n 1 | cut -c 1-1)

    # If no files found create the first file
    if [ -z "$last_file_number" ]; then
        file_path="$log_dir/"$rtla_mode"/"$run_mode"/1_"$rtla_mode"_"$run_mode"-$timestamp.log"
    else
        # If files found, increment the last file number and create a new file
        new_file_number=$((last_file_number + 1))
        file_path="$log_dir/"$rtla_mode"/"$run_mode"/${new_file_number}_"$rtla_mode"_"$run_mode"-$timestamp.log"
    fi

    touch "$file_path"
    echo "$file_path"
}

# No storage option for rtla top mode
if [[ "$storage_mode" == "y" ]]; then
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
if [[ -n "$events" ]]; then
  # Convert events string to an array
  IFS=' ' read -r -a events_arr <<< "$events"
  
  # Validate each element in the array
  for index in "${!events_arr[@]}"; do
    event="${events_arr[index]}"
    
    # If element is '-e', next element should be a valid filter
    if [[ "$event" == '-e' ]]; then
      if (( index + 1 < ${#events_arr[@]} )); then
        filter="${events_arr[index + 1]}"
        if ! echo "$filter" | grep -Pq "^[a-zA-Z0-9_]+(:[a-zA-Z0-9_]+)?$"; then
          echo "Invalid filter format: $filter. It must be one word or two sets of words with a colon in between. Each word can include underscore '_' but no spaces."
          exit 1
        fi
      else
        echo "No filter found after '-e'. Please ensure each '-e' is followed by a valid filter."
        exit 1
      fi
    elif [[ "$event" == -* ]]; then
      echo "Invalid flag: $event. The only allowed flag is '-e'."
      exit 1
    fi
  done
fi



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
case "$rtla_mode" in
  "timerlat"|"hwnoise"|"osnoise")
    echo "Operating in $rtla_mode mode." | storage
    ;;
  *)
    echo "Error: Invalid mode. Please set rtla_mode to 'timerlat', 'hwnoise', or 'osnoise'." | storage
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
if [[ "$rtla_top" == "y" ]]; then
    mode="top"
fi

# hwnoise does not support either hist or top, so set this to blank so we can use generic logic.
if [[ "$rtla_mode" == "hwnoise" ]]; then
    mode=""
fi

# Set the generic shared components of the tools
command_args=("rtla" "$rtla_mode" "$mode" "-c" "$cpulist")

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

if [[ "${threshold}" -ne 0 ]]; then
    command_args=("${command_args[@]}" "-T" "$threshold")
elif [[ "${aa_threshold}" -eq 0 && "${threshold}" -eq 0 ]]; then
    echo "Not using --auto-analysis feature"
else
    command_args=("${command_args[@]}" "-a" "$aa_threshold")
fi

if [[ -n "$custom_options" ]]; then
    for opt in "${custom_options_arr[@]}"; do
        command_args=("${command_args[@]}" "$opt")
    done
fi

if [[ -n "$events" ]]; then
    command_args=("${command_args[@]}" "$events")
fi



echo "running cmd: "${command_args[@]}"" | storage
if [[ "${manual}" == "y" ]]; then
    echo "Entering into manual intervention mode" | storage
    sleep infinity
fi

if [[ "${delay}" != "0" ]]; then
    echo "sleep ${delay} before test" | storage
    sleep ${delay}
fi

# Due to some wierdness in the hist and top outputs, the 
# storage() function swallows this output when storage_mode=n
# Setting this so that the rtla output is not swallowed.
if [[ "$storage_mode" == "y" ]]; then
    "${command_args[@]}" | storage
else 
    "${command_args[@]}"
fi


if [[ "$pause" == "y" ]]; then
    sleep infinity
fi 

if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
    enable_balance
fi

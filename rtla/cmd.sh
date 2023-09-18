#!/bin/bash

# env vars:
#   DURATION (default: no timer for osnoise and timerlat, the default for hwnoise is 24h)
#   DISABLE_CPU_BALANCE (default "n", choices y/n)
#   HOUSEKEEPING_PER_NUMA (default 0, set the number of housekeeping cores per NUMA node. Overrides measurement configs.)
#   ALLCPUSET (default "n", choices y/n, On some machines (like VMs, this value returns 0 for cpuset. This option allows you to use all cores in this case.))
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
    echo "  HOUSEKEEPING_PER_NUMA=value Set the number of housekeeping cores per NUMA node. Default is 0. Overrides measurement configs."
    echo "  ALLCPUSET=value      Use when no CPUSET is defined to tell rtla to use all cores as measurement. Default is 'n'. Choices are 'y' or 'n'."
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
HOUSEKEEPING_PER_NUMA=${HOUSEKEEPING_PER_NUMA:-0}
ALLCPUSET=${ALLCPUSET:-n}
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

simplify_ranges() {
    local ranges=$1
    local IFS=,
    local -a range_array=($ranges)
    local -a result=()
    for range in "${range_array[@]}"; do
        if [[ $range == *-* ]]; then
            local start=${range%-*}
            local end=${range#*-}
            if [[ $start -eq $end ]]; then
                result+=("$start")
            else
                result+=("$range")
            fi
        else
            result+=("$range")
        fi
    done
    echo "${result[*]// /,}"
}

convert_list_to_ranges() {
    local input_string=$1
    input_string=${input_string//,/ } # Replace commas with spaces
    local -a numbers=($input_string)  # Convert the string to an array
    local -a result=()
    local start=${numbers[0]}
    local last=${numbers[0]}
    
    for num in "${numbers[@]:1}"; do
        if [[ $(( last + 1 )) -eq $num ]]; then
            last=$num
        else
            if [[ $start -eq $last ]]; then
                result+=("$start")
            else
                result+=("$start-$last")
            fi
            start=$num
            last=$num
        fi
    done

    # Handle the last segment
    if [[ $start -eq $last ]]; then
        result+=("$start")
    else
        result+=("$start-$last")
    fi
    
    echo "${result[@]}"
}

sort_comma_delimited_list() {
    local comma_delimited="$1"
    
    # Convert comma-delimited string to array
    IFS=',' read -ra nums <<< "$comma_delimited"
    
    # Sort the array
    IFS=$'\n' sorted_nums=($(sort -n <<<"${nums[*]}"))
    unset IFS
    
    # Convert sorted array back to a comma-delimited string
    echo $(IFS=,; echo "${sorted_nums[*]}")
}

declare -A numa_cpu_map

build_numa_cpu_list() {
    for node in /sys/devices/system/node/node[0-9]*; do
        if [[ -d "$node" ]]; then
            local node_num="${node##*/node}"
            local -a cpu_array=()  # declare an array

            for cpu_dir in "$node"/cpu*; do
                if [[ -d "$cpu_dir" ]]; then
                    local cpu_num="${cpu_dir##*/cpu}"
                    cpu_array+=("$cpu_num")  # append to the array
                fi
            done

            # Sort the array
            IFS=$'\n' sorted_cpu_array=($(sort -n <<<"${cpu_array[*]}"))
            unset IFS

            # Convert sorted array to a comma-separated string
            local cpu_list=$(IFS=,; echo "${sorted_cpu_array[*]}")

            all_numa_cpu_map["$node_num"]="$cpu_list"
        fi
    done
}

build_numa_cpu_list_per_set() {
    build_numa_cpu_list #populate needed info
    local cpuset="$1"
    local -a cpuset_array=()

    IFS=',' read -ra cpuset_ranges <<< "$cpuset"
    for range in "${cpuset_ranges[@]}"; do
        if [[ "$range" =~ "-" ]]; then
            IFS='-' read start end <<< "$range"
            for ((i=start; i<=end; i++)); do
                cpuset_array+=("$i")
            done
        else
            cpuset_array+=("$range")
        fi
    done

    for node in /sys/devices/system/node/node[0-9]*; do
        if [[ -d "$node" ]]; then
            local node_num="${node##*/node}"
            local -a cpu_array=()

            for cpu_dir in "$node"/cpu*; do
                if [[ -d "$cpu_dir" ]]; then
                    local cpu_num="${cpu_dir##*/cpu}"
                    # check if this cpu_num is in cpuset_array
                    if [[ " ${cpuset_array[@]} " =~ " ${cpu_num} " ]]; then
                        cpu_array+=("$cpu_num")  # append to the array
                    fi
                fi
            done

            # Sort the array
            IFS=$'\n' sorted_cpu_array=($(sort -n <<<"${cpu_array[*]}"))
            unset IFS

            # Convert sorted array to a comma-separated string
            local cpu_list=$(IFS=,; echo "${sorted_cpu_array[*]}")

            numa_cpu_map["$node_num"]="$cpu_list"
        fi
    done
    print_numa_nodes_and_cpus
}


# This should probably be combined with the build_numa_cpu_list function
print_numa_nodes_and_cpus() {
    echo "NUMA Information for Host:"
    for node_num in "${!all_numa_cpu_map[@]}"; do
        echo "NUMA Node $node_num: ${all_numa_cpu_map[$node_num]}"
    done
    echo "NUMA Information per cpuset:"
    # Collect keys and sort them
    keys=("${!numa_cpu_map[@]}")
    sorted_keys=($(echo "${keys[@]}" | tr ' ' '\n' | sort -n))

    for node_num in "${sorted_keys[@]}"; do
        echo "NUMA Node $node_num: ${numa_cpu_map[$node_num]}"
    done

}

populate_numa_info() {
    local provided_cpuset="$1"
    local housekeeping_per_numa="${HOUSEKEEPING_PER_NUMA:-1}"  # Default to 1 if not provided

    declare -A numa_cores_map
    declare -A reserved_numa_cores_count

    work_cores=""
    housekeeping_cores=""

    # Build the numa cpu list
    build_numa_cpu_list_per_set $provided_cpuset
    total_cpus_in_current_node=0
    IFS=',' read -ra provided_ranges <<< "$provided_cpuset"

    #TODO This needs to first loop through each numa nodes range AND then look through each range
    for current_node in "${!numa_cpu_map[@]}"; do
        total_cpus_in_current_node=0
        IFS=',' read -ra node_ranges <<< "${numa_cpu_map[$current_node]}"
        for range in "${node_ranges[@]}"; do
            local start=${range%-*}
            local end=${range#*-}
            total_cpus_in_current_node=$(( total_cpus_in_current_node + end - start + 1 ))
        done

        # Check if there are no cores available for this node
        if [[ $total_cpus_in_current_node -eq 0 ]]; then
            continue
        fi

        # Check if this node only has one CPU
        if [[ $total_cpus_in_current_node -eq 1 ]]; then
            echo "Warning: NUMA Node $current_node has only one CPU!"
            
            # Directly extracting the only CPU for this node.
            sole_cpu="${node_ranges[0]}"
            
            housekeeping_cores+="$sole_cpu,"
            work_cores+="$sole_cpu,"
            
            continue  # Move to the next NUMA node
        fi

        # Check if HOUSEKEEPING_PER_NODE exceeds the available CPUs on this node
        if [[ $housekeeping_per_numa -gt $total_cpus_in_current_node ]]; then
            echo "Warning: HOUSEKEEPING_PER_NODE ($housekeeping_per_numa) exceeds available CPUs ($total_cpus_in_current_node) on NUMA Node $current_node. Adjusting..."
            cores_to_reserve_for_this_node=$((total_cpus_in_current_node / 2))
        else
            cores_to_reserve_for_this_node=$housekeeping_per_numa
        fi

        for node_range in "${node_ranges[@]}"; do
            local start_core=${node_range%-*}
            local end_core=${node_range#*-}

            # Check if this node_range is in provided_ranges
            for provided_range in "${provided_ranges[@]}"; do
                local provided_start=${provided_range%-*}
                local provided_end=${provided_range#*-}

                # If this node_range intersects with the provided_range, process it
                if [[ $start_core -le $provided_end && $end_core -ge $provided_start ]]; then
                    # Adjust start and end cores if they are outside the provided range
                    [[ $start_core -lt $provided_start ]] && start_core=$provided_start
                    [[ $end_core -gt $provided_end ]] && end_core=$provided_end

                    # Check cores to reserve for this NUMA node
                    local cores_to_reserve_for_this_node=$housekeeping_per_numa
                    if [[ -v reserved_numa_cores_count["$current_node"] ]]; then
                        cores_to_reserve_for_this_node=$((housekeeping_per_numa - reserved_numa_cores_count["$current_node"]))
                    fi

                    # Reserve cores for housekeeping
                    for ((i=0; i<cores_to_reserve_for_this_node && start_core<=end_core; i++)); do
                        housekeeping_cores+="$start_core,"
                        reserved_numa_cores_count["$current_node"]=$((reserved_numa_cores_count["$current_node"] + 1))
                        start_core=$((start_core + 1))
                    done

                    # Append to work cores
                    if [[ $start_core -le $end_core ]]; then
                        local remaining_range="$start_core-$end_core"
                        work_cores+="$remaining_range,"
                    fi
                fi
            done
        done
    done


    # Trim trailing commas
    work_cores="${work_cores%,}"
    housekeeping_cores="${housekeeping_cores%,}"

    # Cleanup and sort the CPUs
    simplify_work_cores=$(simplify_ranges "$work_cores")
    sorted_work_cores=$(sort_comma_delimited_list "$simplify_work_cores")
    work_cores=$(convert_list_to_ranges "$sorted_work_cores")
    # Replace spaces with commas
    work_cores=$(echo "$work_cores" | sed 's/ /,/g')
    
    echo "Work cores: $work_cores"

    simplify_housekeeping_cores=$(simplify_ranges "$housekeeping_cores")
    sorted_hk_cores=$(sort_comma_delimited_list "$simplify_housekeeping_cores")
    housekeeping_cores=$(convert_list_to_ranges "$sorted_hk_cores")
    # Replace spaces with commas
    housekeeping_cores=$(echo "$housekeeping_cores" | sed 's/ /,/g')
    echo "Housekeeping cores: $housekeeping_cores"
}




function get_host_cores() {
	local present_cores=$(cat /sys/devices/system/cpu/present)
	echo ${present_cores}
}


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

cpuset=`get_allowed_cpuset`
echo "cpuset: $cpuset" | storage

## ALLCPUSET handles a bug in rhel9 (and possible others) where cpuset is 0 when no cpuset is defined.
## Deprecate this once the bug is fixed.
if [[ "$cpuset" == "0" && "$ALLCPUSET" == "y" ]]; then
    echo "present cpus: " | storage
    work_cores=`get_host_cores`
    echo "Info: No cpu-set used, using all CPUs" | storage
    echo "WARNING: If trying to run on CPU0, make sure ALLCPUSET=n (Default behavior)" | storage
    #populate_numa_info
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

# This should be removed?
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
command_args=("rtla" "$RTLA_MODE" "$mode" "-c" "$work_cores")

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
    echo "Pausing after run" | storage
    sleep infinity
fi 

if [ "${DISABLE_CPU_BALANCE:-n}" == "y" ]; then
    enable_balance
fi

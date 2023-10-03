function convert_number_range() {
        # converts a range of cpus, like "1-3,5" to a list, like "1,2,3,5"
        local cpu_range=$1
        local cpus_list=""
        local cpus=""
        for cpus in `echo "$cpu_range" | sed -e 's/,/ /g'`; do
                if echo "$cpus" | grep -q -- "-"; then
                        cpus=`echo $cpus | sed -e 's/-/ /'`
                        cpus=`seq $cpus | sed -e 's/ /,/g'`
                fi
                for cpu in $cpus; do
                        cpus_list="$cpus_list,$cpu"
                done
        done
        cpus_list=`echo $cpus_list | sed -e 's/^,//'`
        echo "$cpus_list"
}


function get_allowed_cpuset() {
	local cpuset=`cat /proc/self/status | grep Cpus_allowed_list: | cut -f 2`
	echo ${cpuset}
}


function disable_balance()
{
	local cpu=""
	local file=
	local flags_cur=
	for cpu in ${cpulist}; do
		for file in $(find /proc/sys/kernel/sched_domain/cpu$cpu -name flags -print); do
			flags_cur=$(cat $file)
			flags_cur=$((flags_cur & 0xfffe))
			echo $flags_cur > $file
		done
	done
}


function enable_balance()
{
	local cpu=""
	local file=
	local flags_cur=
	for cpu in ${cpulist}; do
		for file in $(find /proc/sys/kernel/sched_domain/cpu$cpu -name flags -print); do
			flags_cur=$(cat $file)
			flags_cur=$((flags_cur | 0x1))
			echo $flags_cur > $file
		done
	done
}

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

determineHKSiblings() {
    local hk_list="$1"
    local worker_list="$2"
    
    local -a new_hk_list=()
    local -a new_worker_list=()

    # Convert comma-separated lists to arrays
    IFS=',' read -ra hk_array <<< "$hk_list"
    IFS=',' read -ra worker_array <<< "$worker_list"

    for hk_cpu in "${hk_array[@]}"; do
        # Fetch the sibling of the housekeeping CPU
        local sibling=$(cat /sys/devices/system/cpu/cpu$hk_cpu/topology/thread_siblings_list | awk -F '[-,]' '{print $2}')
        if [[ "$sibling" =~ ^[0-9]+$ ]]; then
            echo "CPU$sibling is a sibling of housekeeping CPU$hk_cpu."
            
            # Remove sibling from the worker list if it exists there
            for i in "${!worker_array[@]}"; do
                if [[ "${worker_array[$i]}" == "$sibling" ]]; then
                    unset 'worker_array[i]'
					worker_array=("${worker_array[@]}") #Reindex the array
                fi
            done
            
            # Add sibling to the housekeeping list
            new_hk_list+=("$sibling")
        fi
        new_hk_list+=("$hk_cpu")
    done

    new_worker_list=("${worker_array[@]}")

    # Convert arrays back to comma-separated strings
    updated_hk_list=$(IFS=,; echo "${new_hk_list[*]}")
    updated_worker_list=$(IFS=,; echo "${new_worker_list[*]}")

	updated_hk_list=$(sort_comma_delimited_list "$updated_hk_list")
	updated_worker_list=$(sort_comma_delimited_list "$updated_worker_list")

    echo "Updated Housekeeping CPU List: $updated_hk_list"
    echo "Updated Worker CPU List: $updated_worker_list"
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
	simplify_housekeeping_cores=$(simplify_ranges "$housekeeping_cores")
	sorted_work_cores=$(sort_comma_delimited_list "$simplify_work_cores")
	sorted_hk_cores=$(sort_comma_delimited_list "$simplify_housekeeping_cores")

	# Handle hyperthreading logic per housekeeping CPU
	determineHKSiblings $sorted_hk_cores $sorted_work_cores
	sorted_hk_cores=$updated_hk_list
	sorted_work_cores=$updated_worker_list

	# At this point we have a long list of comma separated cores
	# Add sibling logic here
    work_cores=$(convert_list_to_ranges "$sorted_work_cores")
    # Replace spaces with commas
    work_cores=$(echo "$work_cores" | sed 's/ /,/g')
    
    echo "Work cores: $work_cores"

    
    housekeeping_cores=$(convert_list_to_ranges "$sorted_hk_cores")
    # Replace spaces with commas
    housekeeping_cores=$(echo "$housekeeping_cores" | sed 's/ /,/g')
    echo "Housekeeping cores: $housekeeping_cores"
}

function get_host_cores() {
	local present_cores=$(cat /sys/devices/system/cpu/present)
	echo ${present_cores}
}

function create_file() {
	tool=$1
	run_mode=$2
	required_dirs=$3
	if [ -z "$run_mode" ]; then
		run_mode="default"
	fi
    log_dir="/var/log/app"

    # Check if directories exist, if not, create them
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$log_dir/$dir" ]; then
            mkdir -p "$log_dir/$dir"
        fi
    done

    timestamp=$(date +%Y%m%d%H%M%S)

    # Get the latest file number
    last_file_number=$(ls $log_dir/"$tool"/"$run_mode" | grep $tool | grep $run_mode | sort -n | tail -n 1 | cut -c 1-1)

    # If no files found create the first file
    if [ -z "$last_file_number" ]; then
        file_path="$log_dir/"$tool"/"$run_mode"/1_"$tool"_"$run_mode"-$timestamp.log"
    else
        # If files found, increment the last file number and create a new file
        new_file_number=$((last_file_number + 1))
        file_path="$log_dir/"$tool"/"$run_mode"/${new_file_number}_"$tool"_"$run_mode"-$timestamp.log"
    fi

    touch "$file_path"
    echo "$file_path"
}

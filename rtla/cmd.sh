#!/bin/bash
#
# This file is part of container-perf-tools project.
#
# Copyright (C) 2023 Red Hat, Inc. - Chris White
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#

# env vars:
#   DURATION (default: no timer for osnoise and timerlat, the default for hwnoise is 24h)
#   DISABLE_CPU_BALANCE (default "n", choices y/n)
#   PRIO (RT priority, default "". If no option passed, uses rtla defaults. Choices [policy:priority]. fifo=f:10, round-robin=r:5,other=o:1, deadline=d:500000:1000000)
#   rtla_top (default "n", choices y/n, ignored for hwnoise. Defaults to build a histogram when n)
#   rlta_mode (default "error", choices "timerlat", "hwnoise", or "osnoise". If none are given, we error.)
#   storage_mode (default "n", choices y/n, changes rtla_mode to hist.)
#   pause (default: y, pauses after run. choices y/n)
#   delay (default 0, specify how many seconds to delay before test start)

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

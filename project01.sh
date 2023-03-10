#!/usr/bin/env bash

# ------------ Variables ------------

input_folder="."
output_folder="."
executables=()
pids=()
proc_pids=()

# ------------ Functions ------------

## Install dependencies neeeded to retrieve data ##
install_deps() {
    if ! command -v ifstat &>/dev/null; then
        echo "ifstat not found. Installing it..."
        sudo dnf install -y ifstat
        echo "ifstat installed correctly."
    fi

    if ! command -v iostat &>/dev/null; then
        echo "sysstat not found. Installing it..."
        sudo dnf install -y sysstat
        echo "sysstat installed correctly."
    fi

    if ! command -v gcc &>/dev/null; then
        echo "gcc not found. Installing it..."
        sudo dnf install -y gcc
        echo "gcc installed correctly."
    fi

    echo
}

## Show an help dialog when running the script with the -h or --help flag ##
show_help_message() {
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo "APM Tool to monitor process and system level metrics"
    echo ""
    echo "Options:"
    echo "  -h, --help                Display this help message"
    echo "  -i, --input <folder>      Specify the folder where the c programs are placed (default: ./)"
    echo "  -o, --output <folder>     Specify the folder to output files to (default: ./)"
    echo ""
    echo "Examples:"
    echo "  $0 -i c_folder -o csv_folder"
    echo "  $0 -o /var/logs/project"
}

## Loop through the input folder for all c files and compile them ##
## The executable name will be the name of the c file without extension ##
compile_c_scripts() {
    echo "Compiling c scripts..."
    for file in "$input_folder"/*.c; do
        local output_file_name="${file%.*}"
        gcc "$file" -o "$output_file_name"
        executables+=( "$output_file_name" )
        echo "  $output_file_name compiled"
    done
    echo "All c scripts compiled."
    echo
}

## Parse through flags ##
parse_flags() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help_message
                exit 0
                ;;
            -o|--output)
                output_folder="$2"
                if [ ! -d "$output_folder" ]; then
                    mkdir -p "$output_folder"
                else
                    rm -r "$output_folder"/*
                fi
                echo "Selected output folder: $output_folder"
                shift 2
                ;;
            -i|--input)
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    echo "Input folder not specified"
                    exit 1
                fi
                input_folder="$2"
                if [ ! -d "$input_folder" ]; then
                    echo "Input folder not found"
                    exit 1
                fi
                echo "Selected input folder: $input_folder"
                shift 2
                ;;
            *)
                echo "Unknown flag: $1"
                shift
                ;;
        esac
    done
    set -- "$@"

    echo
}

## Loop through the executables and run them in the background ##
start_processes() {
    local nic=$(hostname -I | awk '{print $1}')
    echo "NIC found: $nic"

    if [ ${#executables[@]} -eq 0 ]; then
        echo "Error: No C executables provided."
        exit 1
    fi

    echo "Starting executables..."
    for executable in "${executables[@]}"; do
        ./"$executable" "$nic" &
        pids+=( $! )
        echo "  $executable ($!) started."
    done
    echo
}

## Append text to file in the output directory ##
append_to_file() {
    local file_name="$1"
    local content="$2"

    echo "$content" >> "$output_folder/$file_name"
}

## Loop through the pids and get cpu and memory ##
## Append the result to a csv file ##
get_process_metrics() {
    for pid in "${pids[@]}"; do
        proc_name=$(ps -p "$pid" -o comm=)

        if [[ -z "$proc_name" ]]; then
            continue
        fi

        file_name="${proc_name}_metrics.csv"
        echo "seconds,%CPU,%memory" > "$output_folder/$file_name"

        while true; do
            cpu=$(ps -p "$pid" -o %cpu= | sed 's/ //g')
            mem=$(ps -p "$pid" -o %mem= | sed 's/ //g')

            append_to_file "$file_name" "$((SECONDS)),$cpu,$mem"
            sleep 5
        done &

        proc_pids+=( $! )
    done
}

## Get system metrics and append the result to a csv file ##
get_system_metrics() {
    local file_name="system_metrics.csv"

    echo "seconds,RX data rate,TX data rate,disk writes,available disk capacity" > "$output_folder/$file_name"

    ifstat ens192 -d 1 2> /dev/null

    while true; do
        rx=$(ifstat ens192 -j | jq 'keys[0] as $key | .[$key].ens192.rx_bytes/1024' | xargs printf "%.2f")
        tx=$(ifstat ens192 -j | jq 'keys[0] as $key | .[$key].ens192.tx_bytes/1024' | xargs printf "%.2f")
        disk_writes=$(iostat -d -o JSON | jq '.sysstat.hosts[0].statistics[0].disk[] | select(.disk_device == "sda") | .["kB_wrtn/s"]')
        disk_capacity=$(df -m / | awk 'NR==2{print $4}')

        append_to_file "$file_name" "$((SECONDS)),$rx,$tx,$disk_writes,$disk_capacity"
        sleep 5
    done &

    proc_pids+=( $! )
}

## Clean up when the script is terminated ##
cleanup() {
    echo "Cleaning up c executable processes..."

    for pid in "${pids[@]}"; do
        kill "$pid"
    done

    echo "C executables processes killed."
    echo

    echo "Cleaning up child processes..."

    for pid in "${proc_pids[@]}"; do
        kill "$pid"
    done

    echo "Child processes killed."
    echo

    echo "Cleaning ifstat..."

    ifstat_pid=$(pgrep ifstat)

    if [[ -n "$ifstat_pid" ]]; then
        kill $ifstat_pid
        echo "ifstat killed."
    else
        echo "ifstat not running. Skipping..."
    fi
}

# ------------ Start of Script ------------

trap cleanup EXIT

parse_flags "$@"

install_deps
compile_c_scripts

start_processes

echo "get_process_metrics starting..."
get_process_metrics &
echo "get_system_metrics starting..."
get_system_metrics &

wait

# ------------ End of Script ------------

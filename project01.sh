#!/usr/bin/env bash

# ------------ Variables ------------

input_folder="."
output_folder="."
executables=()
pids=()
proc_pids=()

# ------------ Functions ------------

get_nic() {
    # local nic=$(ip addr show dev eth2 | grep -E -o "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -n 1)
    # if echo "$nic" | grep -E -q "^([0-9]{1,3}\.){3}[0-9]{1,3}$"; then
    #     nic=$(hostname -I | awk '{print $1}')
    # fi

    # echo "$nic"

    nic=$(hostname -I | awk '{print $1}')

    echo $nic
}

## Install dependencies neeeded to retrieve data ##
install_deps() {
    if ! command -v ifstat &>/dev/null; then
        echo "ifstat not found. Installing it..."
        sudo yum install -y ifstat
        echo "ifstat installed correctly."
    fi

    if ! command -v iostat &>/dev/null; then
        echo "iostat not found. Installing it..."
        sudo yum install -y iostat
        echo "iostat installed correctly."
    fi

    if ! command -v gcc &>/dev/null; then
        echo "gcc not found. Installing it..."
        sudo yum install -y gcc
        echo "gcc installed correctly."
    fi
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
    for file in "$input_folder"/*.c; do
        local output_file_name="${file%.*}"
        gcc "$file" -o "$output_file_name"
        executables+=( "$output_file_name" )
    done
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
                fi
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
                shift 2
                ;;
            *)
                echo "Unknown flag: $1"
                shift
                ;;
        esac
    done
    set -- "$@"
}

## Loop through the executables and run them in the background ##
start_processes() {
    local nic=$(get_nic)

    if [ ${#executables[@]} -eq 0 ]; then
        echo "Error: No C executables provided."
        exit 1
    fi

    for executable in "$executables[@]"; do
        ./"$executable" "$nic" &
        pids+=( $! )
    done
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

        file_name="${proc_name}_metrics.csv"
        echo "seconds,%CPU,%memory" > "$output_folder/$file_name"

        while true; do
            cpu=$(ps -p "$pid" -o %cpu=)
            mem=$(ps -p "$pid" -o %mem=)

            append_to_file "$file_name" "$((SECONDS-1)),$cpu,$mem"
            sleep 5
        done &

        proc_pids+=( $! )
    done
}

## Get system metrics and append the result to a csv file ##
get_system_metrics() {
    local file_name="system_metrics.csv"

    echo "seconds,RX data rate,TX data rate,disk writes,available disk capacity" > "$output_folder/$file_name"

    while true; do
        rx=$(ifstat -t 5 ens192 | awk 'NR==4{print $4}')
        tx=$(ifstat -t 5 ens192 | awk 'NR==4{print $8}')
        disk_writes=$(iostat -d -k 1 2 | awk 'NR==2{print $4}')
        disk_capacity=$(df -m / | awk 'NR==2{print $4}')

        append_to_file "$file_name" "$((SECONDS-1)),$rx,$tx,$disk_writes,$disk_capacity"
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
}

# ------------ Start of Script ------------

trap cleanup INT TERM

parse_flags "$@"

install_deps
compile_c_scripts

start_processes

get_process_metrics &
get_system_metrics &

wait

# ------------ End of Script ------------

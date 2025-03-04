function dsync() {
    local script_path="${${(%):-%x}:h}/dsync.sh"
    echo "Trying to execute: $script_path"
    if [[ -f "$script_path" ]]; then
        echo "Script exists"
        bash "$script_path" "$@"
    else
        echo "Script not found at: $script_path"
        return 1
    fi
} 
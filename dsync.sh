#!/bin/bash

# Function for cleanup on interrupt
cleanup() {
    echo
    log_message "INFO" "Script interrupted, cleaning up..."
    # Add any cleanup tasks here if needed
    exit 1
}

# Set up trap for SIGINT (Ctrl+C) and SIGTERM
trap cleanup INT TERM

# Constants
DSYNC_FILE=".dsync"
MENU_SYNC=1
MENU_ASSOCIATE=2

# Centralized rsync exclude patterns
RSYNC_EXCLUDES=(
    ".dsync"
    ".Trash*"
    ".trash*"
    "lost+found"
    # Add any new excludes here
)

# Function to generate rsync exclude arguments
get_rsync_excludes() {
    local excludes=""
    for pattern in "${RSYNC_EXCLUDES[@]}"; do
        excludes="$excludes --exclude=\"$pattern\""
    done
    echo "$excludes"
}

# Check for rsync installation
check_prerequisites() {
    if ! command -v rsync &> /dev/null; then
        echo "rsync is not installed. Please install it first."
        echo "On Ubuntu/Debian: sudo apt-get install rsync"
        echo "On CentOS/RHEL: sudo yum install rsync"
        exit 1
    fi
}

# Function to generate UUID
generate_uuid() {
    uuidgen || cat /proc/sys/kernel/random/uuid
}

# Function to get current timestamp in ISO-8601 format
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Function to check if drive is properly mounted
check_mount_status() {
    local drive=$1
    
    # Check if the path is actually a mount point
    if ! mountpoint -q "$drive"; then
        log_message "ERROR" "$drive is not a valid mount point"
        return 1
    fi
    
    # Check if the mount point is accessible
    if [ ! -r "$drive" ]; then
        log_message "ERROR" "Cannot read from $drive"
        return 1
    fi
    
    return 0
}

# Function to find all mounted external drives
get_external_drives() {
    # Find mounted USB drives under common mount points
    # Only include directories that look like actual mounted drives
    find /run/media /media /mnt -maxdepth 3 -type d 2>/dev/null | \
    grep -E "/media/.*?/|/run/media/.*?/[^/]+$" | \
    grep -v "/\." | \
    while read -r drive; do
        # Only output the drive if it's a valid mount point
        if mountpoint -q "$drive" 2>/dev/null; then
            echo "$drive"
        fi
    done
}

# Function for consistent logging
log_message() {
    local level=$1
    local message=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Function to create .dsync file with logging
create_dsync_file() {
    local drive=$1
    local set_id=$2
    local role=$3
    
    log_message "INFO" "Creating .dsync file for $drive with role: $role"
    
    if ! cat > "${drive}/${DSYNC_FILE}" << EOF
SET_ID=${set_id}
ROLE=${role}
TIMESTAMP=$(get_timestamp)
EOF
    then
        log_message "ERROR" "Failed to create .dsync file for $drive"
        return 1
    fi
    
    log_message "INFO" ".dsync file created successfully for $drive"
    return 0
}

# Function to read .dsync file
read_dsync_file() {
    local file=$1
    if [ -f "$file" ]; then
        if ! validate_dsync_file "$file"; then
            log_message "ERROR" "Cannot read invalid .dsync file: $file"
            return 1
        fi
        source "$file"
        echo "SET_ID=${SET_ID}"
        echo "ROLE=${ROLE}"
        echo "TIMESTAMP=${TIMESTAMP}"
    fi
}

# Function to convert human readable sizes to bytes
convert_to_bytes() {
    local size=$1
    local unit=${size//[0-9.]/}
    local number=${size//[^0-9.]/}
    
    case ${unit^^} in
        "B") echo "${number%.*}" ;;
        "K"|"KB") echo "$((${number%.*} * 1024))" ;;
        "M"|"MB") echo "$((${number%.*} * 1024 * 1024))" ;;
        "G"|"GB") echo "$((${number%.*} * 1024 * 1024 * 1024))" ;;
        "T"|"TB") echo "$((${number%.*} * 1024 * 1024 * 1024 * 1024))" ;;
        *) echo "0" ;;
    esac
}

# Function to convert bytes to human readable format
convert_to_human() {
    local bytes=$1
    if ((bytes < 1024)); then
        echo "${bytes}B"
    elif ((bytes < 1024 * 1024)); then
        echo "$((bytes / 1024))KB"
    elif ((bytes < 1024 * 1024 * 1024)); then
        echo "$((bytes / 1024 / 1024))MB"
    else
        echo "$((bytes / 1024 / 1024 / 1024))GB"
    fi
}

# Function to check space requirements
check_space_requirements() {
    local source=$1
    local dest=$2
    local safety_margin=1.1  # 10% safety margin
    
    # Remove trailing slashes for consistency
    source="${source%/}"
    dest="${dest%/}"
    
    # Get rsync changes output
    local changes=$(eval "rsync -ain --delete --ignore-errors $(get_rsync_excludes) \"$source/\" \"$dest/\"" 2>/dev/null)
    
    # Calculate space needed based on files to be added/updated
    local to_add=$(echo "$changes" | grep "^>f" | wc -l)
    local to_update=$(echo "$changes" | grep "^.f....." | wc -l)
    local to_delete=$(echo "$changes" | grep "^\*deleting" | wc -l)
    
    # Only calculate size if we have files to add or update
    local total_size=0
    if (( to_add > 0 || to_update > 0 )); then
        # Get size of files to be transferred
        local rsync_stats=$(eval "rsync -ain --delete --ignore-errors $(get_rsync_excludes) --stats \"$source/\" \"$dest/\"" 2>/dev/null)
        total_size=$(echo "$rsync_stats" | grep "Total file size:" | sed 's/,//g' | awk '{print $4}')
        
        if [ -z "$total_size" ] || [ "$total_size" = "0" ]; then
            # Fallback to calculating only the size of files that need to be transferred
            total_size=0
            while read -r file; do
                if [[ "$file" == ">f"* ]]; then
                    local filepath="${source}/${file#>f* }"
                    local size=$(du -b "$filepath" 2>/dev/null | cut -f1)
                    total_size=$((total_size + size))
                fi
            done <<< "$changes"
        fi
    fi
    
    # Calculate required space with safety margin
    local required_bytes=$(echo "$total_size * $safety_margin" | bc | cut -d. -f1)
    
    # Get available space on destination
    local available_bytes=$(df --output=avail -B 1 "$dest" | tail -n 1)
    
    echo "   Data needed:        $(convert_to_human $required_bytes)"
    echo "   Available:          $(convert_to_human $available_bytes)"
    echo "   Changes:"
    echo "   • Files to add:     $to_add"
    echo "   • Files to update:  $to_update"
    echo "   • Files to delete:  $to_delete"
    
    if (( available_bytes >= required_bytes )); then
        echo "   Status:            ✓ Sufficient space"
        return 0
    else
        local needed_more=$((required_bytes - available_bytes))
        echo "   Status:            ✗ Insufficient space (need $(convert_to_human $needed_more) more)"
        return 1
    fi
}

# Function to perform sync with summary and cleaner output
perform_sync() {
    local source=$1
    local dest=$2
    local check_only=$3  # New parameter to indicate if this is just a check
    local source_name=$(basename "$source")
    local dest_name=$(basename "$dest")
    
    if [ "$check_only" != "check" ]; then
        echo "$source_name ➜ $dest_name"
    fi
    
    local exclude_args=$(get_rsync_excludes)
    
    # Run rsync in dry-run mode with itemize-changes to get counts
    local changes=$(eval "rsync -ain --delete --ignore-errors $exclude_args \"$source\" \"$dest\"" 2>/dev/null)
    
    # Get counts
    local to_add=$(echo "$changes" | grep "^>f" | wc -l)
    local to_delete=$(echo "$changes" | grep "^\*deleting" | wc -l)
    local to_update=$(echo "$changes" | grep "^.f....." | wc -l)
    
    # Get total size
    local total_size=$(eval "rsync -ain --delete --ignore-errors $exclude_args --stats \"$source\" \"$dest\"" 2>/dev/null | grep "Total file size" | awk '{print $4" "$5}')
    
    if [ "$check_only" = "check" ]; then
        echo "   Changes required:"
        echo "   • Files to be added:    $to_add"
        echo "   • Files to be deleted:  $to_delete"
        echo "   • Files to be updated:  $to_update"
        echo "   • Total data:          $total_size"
        echo
        return 0
    fi
    
    echo "   Progress: "
    if eval "rsync -a --info=progress2 --delete --ignore-errors $exclude_args \"$source\" \"$dest\"" 2>/dev/null; then
        echo "   Status:  ✓ Completed successfully"
    else
        echo "   Status:  ✗ Failed"
        return 1
    fi
    echo
}

# Function to handle drive syncing with logging
sync_drives() {
    local masters=()
    local backups=()
    local valid_backups=()
    
    clear
    log_message "INFO" "Starting drive sync process"
    
    # Find all drives with .dsync files
    for drive in $(get_external_drives); do
        if [ -f "${drive}/${DSYNC_FILE}" ]; then
            if ! validate_dsync_file "${drive}/${DSYNC_FILE}"; then
                log_message "WARNING" "Skipping invalid .dsync file on ${drive}"
                continue
            fi
            source "${drive}/${DSYNC_FILE}"
            if [ "$ROLE" = "master" ]; then
                masters+=("$drive")
                log_message "INFO" "Found master drive: $drive"
            elif [ "$ROLE" = "backup" ]; then
                backups+=("$drive")
                log_message "INFO" "Found backup drive: $drive"
            fi
        fi
    done
    
    if [ ${#masters[@]} -eq 0 ]; then
        log_message "WARNING" "No master drives found"
        echo "No master drives found."
        read -p "Press Enter to return to main menu..."
        return
    fi
    
    # Process each master drive
    for master in "${masters[@]}"; do
        source "${master}/${DSYNC_FILE}"
        master_set_id=$SET_ID
        local matching_backups=()
        local space_check_results=()
        
        log_message "INFO" "Syncing Master: $master"
        echo "----------------------------------------"
        echo "Space Requirements for Backup Drives:"
        echo
        
        # First, check space on all matching backups
        local backup_index=1
        for backup in "${backups[@]}"; do
            source "${backup}/${DSYNC_FILE}"
            if [ "$SET_ID" = "$master_set_id" ]; then
                matching_backups+=("$backup")
                echo "$backup_index. $backup"
                
                # Capture space check output
                if check_space_requirements "$master/" "$backup/"; then
                    space_check_results+=("pass")
                    valid_backups+=("$backup")
                else
                    space_check_results+=("fail")
                fi
                echo
                ((backup_index++))
            fi
        done
        
        echo "----------------------------------------"
        
        # Check if we have any valid backups
        if [ ${#valid_backups[@]} -eq 0 ]; then
            log_message "WARNING" "No backup drives with sufficient space available"
            echo "No backup drives have sufficient space available."
            read -p "Press Enter to return to main menu..."
            return
        fi
        
        echo "----------------------------------------"
        echo -n "Continue with available backup drives? (y/n): "
        read -n1 choice
        echo  # Add newline after choice
        
        if [ "$choice" = "y" ]; then
            echo
            echo "Summary of Changes:"
            echo "----------------------------------------"
            echo
            
            # First show all changes
            local index=1
            for backup in "${valid_backups[@]}"; do
                echo "$index. $(basename "$master") ➜ $(basename "$backup")"
                perform_sync "$master/" "$backup/" "check"
                ((index++))
            done
            
            echo "----------------------------------------"
            echo -n "Proceed with sync operations? (y/n): "
            read -n1 sync_choice
            echo  # Add newline after choice
            
            if [ "$sync_choice" = "y" ]; then
                echo
                echo "Performing Syncs:"
                echo "----------------------------------------"
                echo
                
                # Process each valid backup
                index=1
                for backup in "${valid_backups[@]}"; do
                    echo "$index. Syncing"
                    perform_sync "$master/" "$backup/"
                    ((index++))
                done
                
                echo "----------------------------------------"
                echo "All sync operations completed."
                read -p "Press Enter to return to main menu..."
                return
            else
                # Just return to main menu if user declines
                return
            fi
        else
            # Just return to main menu if not 'y'
            return
        fi
    done
}

# Helper function for arrow key menu
print_menu() {
    local current_row=$1
    local options=("${@:2}")
    local total_options=${#options[@]}

    clear
    echo "Use arrow keys to navigate, Enter to select, q to quit"
    echo "----------------------------------------"
    
    for i in $(seq 0 $((total_options-1))); do
        if [ $i -eq $current_row ]; then
            echo "▶ ${options[$i]}"
        else
            echo "  ${options[$i]}"
        fi
    done
}

# Helper function to handle arrow key input
arrow_menu() {
    local options=("$@")
    local current_row=0
    local key=""
    
    print_menu "$current_row" "${options[@]}"
    
    while true; do
        read -rsn1 input
        if [[ $input = "" ]]; then
            read -rsn2 input
        fi
        
        case $input in
            'q') return 255 ;;  # Quit
            '') echo $current_row; return ;;  # Enter key
            $'\x1B\x5B\x41') # Up arrow
                ((current_row--))
                if [ $current_row -lt 0 ]; then
                    current_row=$((${#options[@]}-1))
                fi
                ;;
            $'\x1B\x5B\x42') # Down arrow
                ((current_row++))
                if [ $current_row -ge ${#options[@]} ]; then
                    current_row=0
                fi
                ;;
        esac
        print_menu "$current_row" "${options[@]}"
    done
}

# Function to validate .dsync file
validate_dsync_file() {
    local file=$1
    local SET_ID=""
    local ROLE=""
    local TIMESTAMP=""
    
    if [ -f "$file" ]; then
        # First try to source the file
        if ! source "$file" 2>/dev/null; then
            log_message "ERROR" "Invalid .dsync file format in $file"
            return 1
        fi
        
        # Explicitly check each required field
        if [ -z "$SET_ID" ]; then
            log_message "ERROR" "Missing SET_ID in $file"
            return 1
        fi
        
        if [ -z "$ROLE" ]; then
            log_message "ERROR" "Missing ROLE in $file"
            return 1
        fi
        
        if [ -z "$TIMESTAMP" ]; then
            log_message "ERROR" "Missing TIMESTAMP in $file"
            return 1
        fi
        
        # Validate ROLE value
        if [[ "$ROLE" != "master" && "$ROLE" != "backup" ]]; then
            log_message "ERROR" "Invalid ROLE value in $file: $ROLE"
            return 1
        fi
        
        return 0
    fi
    
    log_message "ERROR" "File does not exist: $file"
    return 1
}

# Modified associate_drives function with mount checking
associate_drives() {
    local drives=()
    local drive_states=()
    local current_states=()
    local has_master=false
    local master_set_id=""
    local changes_made=false
    
    log_message "INFO" "Starting drive association process"
    
    # Find all drives and check their mount status
    for drive in $(get_external_drives); do
        if ! check_mount_status "$drive"; then
            continue
        fi
        
        drives+=("$drive")
        if [ -f "${drive}/${DSYNC_FILE}" ]; then
            if ! validate_dsync_file "${drive}/${DSYNC_FILE}"; then
                log_message "WARNING" "Invalid .dsync file found on ${drive}, treating as unassigned"
                current_states+=(0)
                drive_states+=(0)
                continue
            fi
            source "${drive}/${DSYNC_FILE}"
            if [ "$ROLE" = "master" ]; then
                current_states+=(1)
                drive_states+=(1)
                has_master=true
                master_set_id="$SET_ID"
                log_message "INFO" "Found existing master drive: $drive"
            elif [ "$ROLE" = "backup" ]; then
                current_states+=(2)
                drive_states+=(2)
                log_message "INFO" "Found existing backup drive: $drive"
            else
                current_states+=(0)
                drive_states+=(0)
            fi
        else
            current_states+=(0)
            drive_states+=(0)
        fi
    done
    
    if [ ${#drives[@]} -eq 0 ]; then
        log_message "WARNING" "No drives found"
        echo "No drives found."
        read -p "Press Enter to continue..."
        return
    fi
    
    local current_row=0
    while true; do
        clear
        echo "Use arrow keys to navigate, 'd' to toggle state, Enter to confirm, q to quit"
        echo "----------------------------------------"
        
        # Display drives with their states
        for i in "${!drives[@]}"; do
            local prefix="  "
            [ $i -eq $current_row ] && prefix="▶ "
            
            local state_text=""
            local current_text=""
            local arrow_text=""
            
            # Get current state text
            case ${current_states[$i]} in
                1) current_text="master" ;;
                2) current_text="backup" ;;
                0) current_text="unassigned" ;;
            esac
            
            # Get new state text
            case ${drive_states[$i]} in
                1) state_text="master" ;;
                2) state_text="backup" ;;
                0) state_text="unassigned" ;;
            esac
            
            # Only show arrow and new state if it's different from current
            if [ ${current_states[$i]} -ne ${drive_states[$i]} ]; then
                arrow_text=" → $state_text"
                changes_made=true
            fi
            
            echo "${prefix}${drives[$i]} ($current_text$arrow_text)"
        done
        
        # Handle key input
        read -rsn1 input
        if [[ $input = $'\e' ]]; then
            read -rsn2 input
            case "$input" in
                '[A') # Up arrow
                    ((current_row--))
                    if [ $current_row -lt 0 ]; then
                        current_row=$((${#drives[@]}-1))
                    fi
                    ;;
                '[B') # Down arrow
                    ((current_row++))
                    if [ $current_row -ge ${#drives[@]} ]; then
                        current_row=0
                    fi
                    ;;
            esac
        elif [[ $input = 'd' ]]; then  # Toggle state
            if [ ${drive_states[$current_row]} -eq 0 ]; then
                if ! $has_master; then
                    drive_states[$current_row]=1
                    has_master=true
                else
                    drive_states[$current_row]=2
                fi
            else
                if [ ${drive_states[$current_row]} -eq 1 ]; then
                    has_master=false
                    # Reset backup states
                    for i in "${!drive_states[@]}"; do
                        if [ ${drive_states[$i]} -eq 2 ]; then
                            drive_states[$i]=0
                        fi
                    done
                fi
                drive_states[$current_row]=0
            fi
            # Check if any changes exist after toggle
            changes_made=false
            for i in "${!drives[@]}"; do
                if [ ${current_states[$i]} -ne ${drive_states[$i]} ]; then
                    changes_made=true
                    break
                fi
            done
        elif [[ $input = 'q' ]]; then
            clear
            return
        elif [[ $input = '' ]]; then  # Enter key - confirm selections
            if ! $changes_made; then
                continue  # Skip to next iteration if no changes were made
            fi
            
            while true; do
                clear
                echo "Review your selections:"
                echo "----------------------------------------"
                for i in "${!drives[@]}"; do
                    local current_text=""
                    local new_text=""
                    local arrow_text=""
                    
                    # Get current state text
                    case ${current_states[$i]} in
                        1) current_text="master" ;;
                        2) current_text="backup" ;;
                        0) current_text="unassigned" ;;
                    esac
                    
                    # Get new state text
                    case ${drive_states[$i]} in
                        1) new_text="master" ;;
                        2) new_text="backup" ;;
                        0) new_text="unassigned" ;;
                    esac
                    
                    # Only show arrow and new state if it's different from current
                    if [ ${current_states[$i]} -ne ${drive_states[$i]} ]; then
                        arrow_text=" → $new_text"
                    fi
                    
                    echo "${drives[$i]} ($current_text$arrow_text)"
                done
                echo "----------------------------------------"
                echo "Press 'y' to confirm, 'n' to go back, 'q' to quit to main menu"
                read -rsn1 confirm
                
                case $confirm in
                    'y')
                        clear
                        echo "Processing drive associations..."
                        echo "----------------------------------------"
                        
                        log_message "INFO" "User confirmed drive associations"
                        master_set_id=$(generate_uuid)
                        for i in "${!drives[@]}"; do
                            case ${drive_states[$i]} in
                                1) 
                                    log_message "INFO" "Setting ${drives[$i]} as master"
                                    create_dsync_file "${drives[$i]}" "$master_set_id" "master"
                                    ;;
                                2)
                                    log_message "INFO" "Setting ${drives[$i]} as backup"
                                    create_dsync_file "${drives[$i]}" "$master_set_id" "backup"
                                    ;;
                                0)
                                    if [ -f "${drives[$i]}/${DSYNC_FILE}" ]; then
                                        log_message "INFO" "Removing .dsync file from ${drives[$i]}"
                                        rm -f "${drives[$i]}/${DSYNC_FILE}"
                                    fi
                                    ;;
                            esac
                        done
                        echo "----------------------------------------"
                        echo "Drive associations completed successfully."
                        read -p "Press Enter to return to main menu..."
                        return
                        ;;
                    'n')
                        break  # Return to selection menu
                        ;;
                    'q')
                        clear
                        return  # Return to main menu
                        ;;
                esac
            done
        fi
    done
}

# Main menu function
show_menu() {
    while true; do
        clear
        echo "╔═══════════════════════════════════╗"
        echo "║           D S Y N C               ║"
        echo "║    Drive Sync Automation Tool     ║"
        echo "╚═══════════════════════════════════╝"
        echo "    Press key (1-3) to select option"
        echo
        echo "1. Sync Drives"
        echo "2. Associate Drives"
        echo "3. Exit"
        
        # Changed from read -k 1 to read -n 1 for bash compatibility
        read -n 1 choice
        echo  # Add newline after choice
        
        case $choice in
            "1") sync_drives ;;
            "2") associate_drives ;;
            "3") 
                log_message "INFO" "User requested exit"
                cleanup
                ;;
            *) continue ;;
        esac
    done
}

# Only run the menu if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Main script execution with logging and signal handling
    log_message "INFO" "Starting DSYNC"
    check_prerequisites
    show_menu
    log_message "INFO" "DSYNC completed"
fi
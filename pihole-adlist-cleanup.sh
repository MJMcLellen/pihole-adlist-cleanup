#!/bin/bash
#
# Pi-hole Adlist Auto-Cleanup Script
# Monitors gravity update failures and removes adlists after 10 failed attempts in 30 days
#
# Installation:
#   1. Copy to /usr/local/bin/pihole-adlist-cleanup.sh
#   2. chmod +x /usr/local/bin/pihole-adlist-cleanup.sh
#   3. Add to crontab: 0 3 * * * /usr/local/bin/pihole-adlist-cleanup.sh
#
# Author: Matt - Rite-Solutions
# License: MIT

# Configuration
FAILURE_THRESHOLD=10        # Number of failures before removal
DAYS_WINDOW=30              # Time window to track failures (days)
LOG_DIR="/var/log/pihole-cleanup"
FAILURE_LOG="$LOG_DIR/adlist_failures.log"
SCRIPT_LOG="$LOG_DIR/cleanup.log"
PIHOLE_DB="/etc/pihole/gravity.db"
DRY_RUN=false              # Set to true for testing without actual removal

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Ensure we're running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root or with sudo${NC}" 
   exit 1
fi

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Initialize failure log if it doesn't exist
if [[ ! -f "$FAILURE_LOG" ]]; then
    echo "timestamp,adlist_id,address,status" > "$FAILURE_LOG"
fi

# Function to log messages
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$SCRIPT_LOG"
}

# Function to check if pihole database exists
check_pihole_db() {
    if [[ ! -f "$PIHOLE_DB" ]]; then
        log_message "ERROR" "Pi-hole database not found at $PIHOLE_DB"
        exit 1
    fi
}

# Function to get current gravity log for failures
parse_gravity_log() {
    local log_file="/var/log/pihole/pihole.log"
    local gravity_log="/var/log/pihole/pihole_gravity.log"
    
    # Check both possible log locations
    if [[ -f "$gravity_log" ]]; then
        log_file="$gravity_log"
    fi
    
    # Parse for inaccessible adlists from the most recent gravity run
    # Looking for pattern: "List with ID X (URL) was inaccessible"
    if [[ -f "$log_file" ]]; then
        grep -E "was inaccessible during last gravity run" "$log_file" 2>/dev/null | \
        grep -oP 'ID \K[0-9]+(?= \(https?://[^)]+\))' | sort -u
    fi
}

# Function to get adlist URL by ID
get_adlist_url() {
    local id=$1
    sqlite3 "$PIHOLE_DB" "SELECT address FROM adlist WHERE id=$id;" 2>/dev/null
}

# Function to get adlist status
get_adlist_status() {
    local id=$1
    sqlite3 "$PIHOLE_DB" "SELECT enabled FROM adlist WHERE id=$id;" 2>/dev/null
}

# Function to record failure
record_failure() {
    local id=$1
    local url=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "$timestamp,$id,$url,failed" >> "$FAILURE_LOG"
    log_message "INFO" "Recorded failure for adlist ID $id: $url"
}

# Function to count failures within the time window
count_recent_failures() {
    local id=$1
    local cutoff_date=$(date -d "$DAYS_WINDOW days ago" '+%Y-%m-%d')
    
    # Count failures for this ID after the cutoff date
    grep ",$id," "$FAILURE_LOG" | \
    awk -F',' -v cutoff="$cutoff_date" '$1 >= cutoff' | \
    wc -l
}

# Function to disable adlist
disable_adlist() {
    local id=$1
    local url=$2
    
    if [[ "$DRY_RUN" == true ]]; then
        log_message "DRY_RUN" "Would disable adlist ID $id: $url"
        return 0
    fi
    
    sqlite3 "$PIHOLE_DB" "UPDATE adlist SET enabled=0 WHERE id=$id;"
    
    if [[ $? -eq 0 ]]; then
        log_message "WARNING" "Disabled adlist ID $id after $FAILURE_THRESHOLD failures: $url"
        
        # Add comment to the adlist explaining why it was disabled
        local comment="Auto-disabled after $FAILURE_THRESHOLD failures in $DAYS_WINDOW days - $(date '+%Y-%m-%d')"
        sqlite3 "$PIHOLE_DB" "UPDATE adlist SET comment='$comment' WHERE id=$id;"
        
        return 0
    else
        log_message "ERROR" "Failed to disable adlist ID $id"
        return 1
    fi
}

# Function to clean old failure records
cleanup_old_failures() {
    local cutoff_date=$(date -d "$((DAYS_WINDOW + 7)) days ago" '+%Y-%m-%d')
    local temp_file="${FAILURE_LOG}.tmp"
    
    # Keep header and recent records
    head -n 1 "$FAILURE_LOG" > "$temp_file"
    awk -F',' -v cutoff="$cutoff_date" '$1 >= cutoff || NR==1' "$FAILURE_LOG" >> "$temp_file"
    
    mv "$temp_file" "$FAILURE_LOG"
    log_message "INFO" "Cleaned up failure records older than $cutoff_date"
}

# Function to send notification (optional - integrate with your notification system)
send_notification() {
    local id=$1
    local url=$2
    local failure_count=$3
    
    # Example: Log to syslog
    logger -t pihole-cleanup "Adlist ID $id disabled after $failure_count failures: $url"
    
    # You could integrate with:
    # - Email notifications
    # - Pushover/Pushbullet
    # - Slack/Discord webhooks
    # - SNMP traps
}

# Main execution
main() {
    log_message "INFO" "=== Starting Pi-hole Adlist Cleanup Check ==="
    
    # Verify Pi-hole database exists
    check_pihole_db
    
    # Parse current gravity failures
    failed_ids=$(parse_gravity_log)
    
    if [[ -z "$failed_ids" ]]; then
        log_message "INFO" "No adlist failures detected in latest gravity run"
    else
        log_message "INFO" "Found failures for adlist IDs: $(echo $failed_ids | tr '\n' ' ')"
        
        # Record each failure
        for id in $failed_ids; do
            url=$(get_adlist_url "$id")
            
            if [[ -n "$url" ]]; then
                record_failure "$id" "$url"
                
                # Check if this adlist has exceeded the failure threshold
                failure_count=$(count_recent_failures "$id")
                
                log_message "INFO" "Adlist ID $id has $failure_count failures in the last $DAYS_WINDOW days"
                
                if [[ $failure_count -ge $FAILURE_THRESHOLD ]]; then
                    # Check if already disabled
                    status=$(get_adlist_status "$id")
                    
                    if [[ "$status" == "1" ]]; then
                        echo -e "${RED}THRESHOLD EXCEEDED${NC}: Adlist ID $id ($url)"
                        echo -e "  Failures: $failure_count in $DAYS_WINDOW days"
                        
                        disable_adlist "$id" "$url"
                        send_notification "$id" "$url" "$failure_count"
                    else
                        log_message "INFO" "Adlist ID $id already disabled, skipping"
                    fi
                fi
            else
                log_message "WARNING" "Could not find URL for adlist ID $id"
            fi
        done
    fi
    
    # Clean up old failure records
    cleanup_old_failures
    
    # Summary
    total_failures=$(tail -n +2 "$FAILURE_LOG" | wc -l)
    unique_adlists=$(tail -n +2 "$FAILURE_LOG" | cut -d',' -f2 | sort -u | wc -l)
    
    log_message "INFO" "Total tracked failures: $total_failures"
    log_message "INFO" "Unique adlists with failures: $unique_adlists"
    log_message "INFO" "=== Adlist Cleanup Check Complete ==="
}

# Handle command line arguments
case "${1:-}" in
    --dry-run)
        DRY_RUN=true
        log_message "INFO" "Running in DRY RUN mode - no changes will be made"
        main
        ;;
    --stats)
        echo "=== Pi-hole Adlist Failure Statistics ==="
        echo ""
        echo "Failure Log: $FAILURE_LOG"
        
        if [[ -f "$FAILURE_LOG" ]]; then
            total=$(tail -n +2 "$FAILURE_LOG" | wc -l)
            unique=$(tail -n +2 "$FAILURE_LOG" | cut -d',' -f2 | sort -u | wc -l)
            
            echo "Total recorded failures: $total"
            echo "Unique adlists with failures: $unique"
            echo ""
            echo "Top failing adlists:"
            tail -n +2 "$FAILURE_LOG" | cut -d',' -f2,3 | sort | uniq -c | sort -rn | head -10
        else
            echo "No failure log found"
        fi
        ;;
    --reset)
        read -p "Are you sure you want to reset the failure log? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            echo "timestamp,adlist_id,address,status" > "$FAILURE_LOG"
            log_message "INFO" "Failure log reset"
            echo "Failure log has been reset"
        else
            echo "Reset cancelled"
        fi
        ;;
    --help)
        cat << EOF
Pi-hole Adlist Auto-Cleanup Script

Usage: $0 [OPTION]

Options:
    (no option)    Run the cleanup check
    --dry-run      Run without making changes (test mode)
    --stats        Show failure statistics
    --reset        Reset the failure log
    --help         Show this help message

Configuration:
    Failure threshold: $FAILURE_THRESHOLD failures
    Time window: $DAYS_WINDOW days
    Logs: $LOG_DIR

The script monitors Pi-hole gravity failures and automatically disables
adlists that fail more than $FAILURE_THRESHOLD times within $DAYS_WINDOW days.

Recommended crontab entry (runs daily at 3 AM):
    0 3 * * * /usr/local/bin/pihole-adlist-cleanup.sh

EOF
        ;;
    *)
        main
        ;;
esac

exit 0

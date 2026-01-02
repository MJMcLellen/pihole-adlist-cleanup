#!/bin/bash
#
# Pi-hole Adlist Auto-Cleanup Script (Security Hardened)
# Monitors gravity update failures and removes adlists after 10 failed attempts in 30 days
#
# Installation:
#   1. Copy to /usr/local/bin/pihole-adlist-cleanup.sh
#   2. chmod +x /usr/local/bin/pihole-adlist-cleanup.sh
#   3. Add to crontab: 0 3 * * * /usr/local/bin/pihole-adlist-cleanup.sh
#
# Author: Matt - Rite-Solutions
# License: MIT
# Version: 2.0 (Security Hardened)

set -uo pipefail  # Exit on undefined variables and pipe failures (removed -e for better control)
IFS=$'\n\t'        # Safer Internal Field Separator

# Configuration
readonly FAILURE_THRESHOLD=10        # Number of failures before removal
readonly DAYS_WINDOW=30              # Time window to track failures (days)
readonly LOG_DIR="/var/log/pihole-cleanup"
readonly FAILURE_LOG="$LOG_DIR/adlist_failures.log"
readonly SCRIPT_LOG="$LOG_DIR/cleanup.log"
readonly PIHOLE_DB="/etc/pihole/gravity.db"
readonly LOCK_FILE="/var/lock/pihole-adlist-cleanup.lock"
LOCK_FD=200

DRY_RUN=false              # Set to true for testing without actual removal

# Color codes for output
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m' # No Color

# Cleanup function for traps
cleanup() {
    local exit_code=$?
    
    # Release lock if held
    if [[ -e "/proc/$$/fd/200" ]]; then
        flock -u 200 2>/dev/null || true
    fi
    
    # Remove lock file
    [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE" 2>/dev/null || true
    
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# Ensure we're running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root or with sudo${NC}" >&2
   exit 1
fi

# Acquire exclusive lock to prevent concurrent execution
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another instance of this script is already running. Exiting." >&2
    exit 0
fi

# Create log directory if it doesn't exist
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    echo -e "${RED}Error: Cannot create log directory: $LOG_DIR${NC}" >&2
    exit 1
fi

# Verify log directory is writable
if [[ ! -w "$LOG_DIR" ]]; then
    echo -e "${RED}Error: Log directory not writable: $LOG_DIR${NC}" >&2
    exit 1
fi

# Initialize failure log if it doesn't exist
if [[ ! -f "$FAILURE_LOG" ]]; then
    echo "timestamp,adlist_id,address,status" > "$FAILURE_LOG" || {
        echo -e "${RED}Error: Cannot create failure log${NC}" >&2
        exit 1
    }
fi

# Function to log messages (thread-safe with file locking)
log_message() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    local log_line="[$timestamp] [$level] $message"
    
    # Print to terminal
    echo "$log_line"
    
    # Write to log file with flock for atomicity
    (
        flock -x 201
        echo "$log_line" >&201
    ) 201>>"$SCRIPT_LOG" 2>/dev/null
}

# Function to validate numeric input (prevent SQL injection)
validate_numeric() {
    local value=$1
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "Invalid numeric value detected: $value"
        return 1
    fi
    return 0
}

# Function to escape SQL strings
escape_sql_string() {
    local string=$1
    # Replace single quotes with two single quotes (SQL escaping)
    echo "${string//\'/\'\'}"
}

# Function to check if pihole database exists and is accessible
check_pihole_db() {
    if [[ ! -f "$PIHOLE_DB" ]]; then
        log_message "ERROR" "Pi-hole database not found at $PIHOLE_DB"
        return 1
    fi
    
    if [[ ! -r "$PIHOLE_DB" ]]; then
        log_message "ERROR" "Pi-hole database not readable: $PIHOLE_DB"
        return 1
    fi
    
    # Test database integrity
    if ! sqlite3 "$PIHOLE_DB" "PRAGMA integrity_check;" >/dev/null 2>&1; then
        log_message "ERROR" "Pi-hole database integrity check failed"
        return 1
    fi
    
    return 0
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
        grep -oP 'ID \K[0-9]+(?= \(https?://[^)]+\))' | \
        sort -u | \
        while read -r id; do
            # Validate each ID before outputting
            if validate_numeric "$id"; then
                echo "$id"
            fi
        done
    fi
}

# Function to get adlist URL by ID (with SQL injection protection)
get_adlist_url() {
    local id=$1
    
    # Validate input
    validate_numeric "$id" || return 1
    
    # Use parameterized-style query (SQLite doesn't support true prepared statements in CLI)
    # But we've validated the input is numeric, so this is safe
    sqlite3 "$PIHOLE_DB" "SELECT address FROM adlist WHERE id=$id;" 2>/dev/null
}

# Function to get adlist status
get_adlist_status() {
    local id=$1
    
    # Validate input
    validate_numeric "$id" || return 1
    
    sqlite3 "$PIHOLE_DB" "SELECT enabled FROM adlist WHERE id=$id;" 2>/dev/null
}

# Function to record failure (atomic append)
record_failure() {
    local id=$1
    local url=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Validate inputs
    validate_numeric "$id" || return 1
    
    # Escape URL for CSV (replace commas with semicolons to avoid CSV issues)
    local escaped_url="${url//,/;}"
    
    # Atomic append with flock
    (
        flock -x 202
        echo "$timestamp,$id,$escaped_url,failed" >> "$FAILURE_LOG"
    ) 202>>"$FAILURE_LOG.lock"
    
    log_message "INFO" "Recorded failure for adlist ID $id: $url"
}

# Optimized function to count failures within the time window
# Reads file once and builds associative array for O(1) lookups
declare -A FAILURE_COUNTS

build_failure_counts() {
    local cutoff_date
    cutoff_date=$(date -d "$DAYS_WINDOW days ago" '+%Y-%m-%d' 2>/dev/null) || {
        # Fallback for non-GNU date (macOS, BSD)
        cutoff_date=$(date -v-"${DAYS_WINDOW}d" '+%Y-%m-%d' 2>/dev/null) || {
            log_message "ERROR" "Cannot calculate cutoff date"
            return 1
        }
    }
    
    # Clear previous counts
    FAILURE_COUNTS=()
    
    # Read file once and count failures per ID
    while IFS=',' read -r timestamp id url status; do
        # Skip header
        [[ "$timestamp" == "timestamp" ]] && continue
        
        # Compare timestamps (lexicographic comparison works for ISO date format)
        if [[ "$timestamp" > "$cutoff_date" ]] || [[ "$timestamp" == "$cutoff_date" ]]; then
            # Increment count for this ID
            ((FAILURE_COUNTS[$id]++)) 2>/dev/null || FAILURE_COUNTS[$id]=1
        fi
    done < "$FAILURE_LOG"
}

# Function to get failure count for a specific ID
get_failure_count() {
    local id=$1
    echo "${FAILURE_COUNTS[$id]:-0}"
}

# Function to disable adlist (with proper SQL escaping)
disable_adlist() {
    local id=$1
    local url=$2
    
    # Validate input
    validate_numeric "$id" || return 1
    
    if [[ "$DRY_RUN" == true ]]; then
        log_message "DRY_RUN" "Would disable adlist ID $id: $url"
        return 0
    fi
    
    # Create comment with proper SQL escaping
    local comment_date
    comment_date=$(date '+%Y-%m-%d')
    local comment="Auto-disabled after $FAILURE_THRESHOLD failures in $DAYS_WINDOW days - $comment_date"
    local escaped_comment
    escaped_comment=$(escape_sql_string "$comment")
    
    # Execute both SQL statements in a transaction for atomicity
    if sqlite3 "$PIHOLE_DB" <<EOF
BEGIN TRANSACTION;
UPDATE adlist SET enabled=0 WHERE id=$id;
UPDATE adlist SET comment='$escaped_comment' WHERE id=$id;
COMMIT;
EOF
    then
        log_message "WARNING" "Disabled adlist ID $id after $FAILURE_THRESHOLD failures: $url"
        return 0
    else
        log_message "ERROR" "Failed to disable adlist ID $id"
        return 1
    fi
}

# Function to clean old failure records (atomic with proper temp file handling)
cleanup_old_failures() {
    local cutoff_date
    cutoff_date=$(date -d "$((DAYS_WINDOW + 7)) days ago" '+%Y-%m-%d' 2>/dev/null) || {
        # Fallback for non-GNU date
        cutoff_date=$(date -v-"$((DAYS_WINDOW + 7))d" '+%Y-%m-%d' 2>/dev/null) || {
            log_message "ERROR" "Cannot calculate cleanup cutoff date"
            return 1
        }
    }
    
    local temp_file
    temp_file=$(mktemp "${FAILURE_LOG}.XXXXXX") || {
        log_message "ERROR" "Cannot create temporary file"
        return 1
    }
    
    # Use flock to ensure atomic operation
    (
        flock -x 203
        
        # Keep header and recent records (single awk pass)
        awk -F',' -v cutoff="$cutoff_date" 'NR==1 || $1 >= cutoff' "$FAILURE_LOG" > "$temp_file"
        
        # Atomic move (same filesystem)
        mv "$temp_file" "$FAILURE_LOG"
        
    ) 203>>"$FAILURE_LOG.lock"
    
    log_message "INFO" "Cleaned up failure records older than $cutoff_date"
}

# Function to send notification (optional - integrate with your notification system)
send_notification() {
    local id=$1
    local url=$2
    local failure_count=$3
    
    # Validate inputs to prevent command injection
    validate_numeric "$id" || return 1
    validate_numeric "$failure_count" || return 1
    
    # Log to syslog (safe - logger handles escaping)
    logger -t pihole-cleanup "Adlist ID $id disabled after $failure_count failures: $url" 2>/dev/null || true
    
    # You could integrate with:
    # - Email notifications
    # - Pushover/Pushbullet
    # - Slack/Discord webhooks
    # - SNMP traps
}

# Main execution
main() {
    log_message "INFO" "=== Starting Pi-hole Adlist Cleanup Check ==="
    
    # Verify Pi-hole database exists and is accessible
    if ! check_pihole_db; then
        log_message "ERROR" "Pi-hole database check failed, aborting"
        return 1
    fi
    
    # Parse current gravity failures
    local failed_ids
    failed_ids=$(parse_gravity_log)
    
    if [[ -z "$failed_ids" ]]; then
        log_message "INFO" "No adlist failures detected in latest gravity run"
    else
        log_message "INFO" "Found failures for adlist IDs: $(echo "$failed_ids" | tr '\n' ' ')"
        
        # Build failure counts once for efficiency (O(n) instead of O(n*m))
        build_failure_counts || {
            log_message "ERROR" "Failed to build failure counts"
            return 1
        }
        
        # Record each failure
        while read -r id; do
            [[ -z "$id" ]] && continue
            
            local url
            url=$(get_adlist_url "$id")
            
            if [[ -n "$url" ]]; then
                record_failure "$id" "$url"
                
                # Check if this adlist has exceeded the failure threshold
                local failure_count
                failure_count=$(get_failure_count "$id")
                
                log_message "INFO" "Adlist ID $id has $failure_count failures in the last $DAYS_WINDOW days"
                
                if [[ $failure_count -ge $FAILURE_THRESHOLD ]]; then
                    # Check if already disabled
                    local status
                    status=$(get_adlist_status "$id")
                    
                    if [[ "$status" == "1" ]]; then
                        echo -e "${RED}THRESHOLD EXCEEDED${NC}: Adlist ID $id ($url)"
                        echo -e "  Failures: $failure_count in $DAYS_WINDOW days"
                        
                        if disable_adlist "$id" "$url"; then
                            send_notification "$id" "$url" "$failure_count"
                        fi
                    else
                        log_message "INFO" "Adlist ID $id already disabled, skipping"
                    fi
                fi
            else
                log_message "WARNING" "Could not find URL for adlist ID $id"
            fi
        done <<< "$failed_ids"
    fi
    
    # Clean up old failure records
    cleanup_old_failures
    
    # Summary
    local total_failures unique_adlists
    total_failures=$(tail -n +2 "$FAILURE_LOG" 2>/dev/null | wc -l || echo "0")
    unique_adlists=$(tail -n +2 "$FAILURE_LOG" 2>/dev/null | cut -d',' -f2 | sort -u | wc -l || echo "0")
    
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
            local total unique
            total=$(tail -n +2 "$FAILURE_LOG" 2>/dev/null | wc -l || echo "0")
            unique=$(tail -n +2 "$FAILURE_LOG" 2>/dev/null | cut -d',' -f2 | sort -u | wc -l || echo "0")
            
            echo "Total recorded failures: $total"
            echo "Unique adlists with failures: $unique"
            echo ""
            echo "Top failing adlists:"
            tail -n +2 "$FAILURE_LOG" 2>/dev/null | cut -d',' -f2,3 | sort | uniq -c | sort -rn | head -10 || echo "No data"
        else
            echo "No failure log found"
        fi
        ;;
    --reset)
        read -r -p "Are you sure you want to reset the failure log? (yes/no): " confirm
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
Pi-hole Adlist Auto-Cleanup Script (Security Hardened v2.0)

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

Security Features:
    - SQL injection protection with input validation
    - Atomic file operations with flock
    - Concurrent execution prevention
    - Proper error handling and exit codes
    - Safe date command fallbacks for non-GNU systems

Recommended crontab entry (runs daily at 3 AM):
    0 3 * * * /usr/local/bin/pihole-adlist-cleanup.sh

EOF
        ;;
    *)
        main
        ;;
esac

exit 0

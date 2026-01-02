# pihole-adlist-cleanup
Automated Pi-hole adlist cleanup script - automatically disables adlists after repeated failures
# Pi-hole Adlist Auto-Cleanup Script - Installation Guide

## Overview

This script automatically monitors Pi-hole gravity update failures and disables adlists that consistently fail to load. After 10 failed attempts over a 30-day period, the script automatically disables the problematic adlist and logs the action.

## Features

- **Automatic Monitoring**: Tracks adlist failures from gravity updates
- **Configurable Thresholds**: Default 10 failures in 30 days (customizable)
- **Safe Operation**: Disables (not deletes) broken adlists
- **Detailed Logging**: Maintains failure history and cleanup logs
- **Dry-Run Mode**: Test without making changes
- **Statistics Reporting**: View failure trends
- **Automatic Cleanup**: Removes old failure records

## Installation

### 1. Copy the Script

```bash
sudo cp pihole-adlist-cleanup.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/pihole-adlist-cleanup.sh
```

### 2. Test the Script

Run in dry-run mode first to see what it would do:

```bash
sudo /usr/local/bin/pihole-adlist-cleanup.sh --dry-run
```

### 3. Set Up Automated Execution

Add to crontab to run daily at 3 AM (after gravity typically runs):

```bash
sudo crontab -e
```

Add this line:

```
0 3 * * * /usr/local/bin/pihole-adlist-cleanup.sh
```

**Alternative**: Run after each gravity update by creating a post-gravity hook:

```bash
# Create the hook directory if it doesn't exist
sudo mkdir -p /etc/pihole/post-update.d

# Create a symlink to the script
sudo ln -s /usr/local/bin/pihole-adlist-cleanup.sh /etc/pihole/post-update.d/01-cleanup-adlists
```

## Configuration

Edit the script to adjust these settings at the top:

```bash
FAILURE_THRESHOLD=10        # Number of failures before removal
DAYS_WINDOW=30              # Time window to track failures (days)
LOG_DIR="/var/log/pihole-cleanup"
```

### Common Configurations

**More aggressive** (remove faster):
```bash
FAILURE_THRESHOLD=5
DAYS_WINDOW=14
```

**More lenient** (give more chances):
```bash
FAILURE_THRESHOLD=20
DAYS_WINDOW=60
```

## Usage

### Basic Usage

Run the cleanup check manually:
```bash
sudo /usr/local/bin/pihole-adlist-cleanup.sh
```

### Dry Run (Test Mode)

See what would happen without making changes:
```bash
sudo /usr/local/bin/pihole-adlist-cleanup.sh --dry-run
```

### View Statistics

Check which adlists are failing:
```bash
sudo /usr/local/bin/pihole-adlist-cleanup.sh --stats
```

Example output:
```
=== Pi-hole Adlist Failure Statistics ===

Failure Log: /var/log/pihole-cleanup/adlist_failures.log
Total recorded failures: 45
Unique adlists with failures: 3

Top failing adlists:
  15 27,https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt
   8 42,https://example.com/blocklist.txt
   5 18,https://another-list.com/domains.txt
```

### Reset Failure Log

Clear all failure history:
```bash
sudo /usr/local/bin/pihole-adlist-cleanup.sh --reset
```

### View Logs

Check the cleanup log:
```bash
sudo tail -f /var/log/pihole-cleanup/cleanup.log
```

Check the failure tracking log:
```bash
sudo cat /var/log/pihole-cleanup/adlist_failures.log
```

## How It Works

1. **Detection**: Script parses Pi-hole logs for "was inaccessible during last gravity run" messages
2. **Recording**: Each failure is logged with timestamp, adlist ID, and URL
3. **Counting**: Counts failures for each adlist within the configured time window
4. **Action**: When threshold is exceeded, the adlist is disabled (not deleted)
5. **Notification**: Logs the action and optionally sends notifications
6. **Cleanup**: Removes failure records older than the time window + 7 days

## Understanding the Logs

### Cleanup Log Format
```
[2025-01-01 03:00:15] [INFO] Starting Pi-hole Adlist Cleanup Check
[2025-01-01 03:00:16] [INFO] Recorded failure for adlist ID 27: https://osint.digitalside.it/...
[2025-01-01 03:00:16] [INFO] Adlist ID 27 has 10 failures in the last 30 days
[2025-01-01 03:00:16] [WARNING] Disabled adlist ID 27 after 10 failures: https://osint.digitalside.it/...
```

### Failure Log Format (CSV)
```
timestamp,adlist_id,address,status
2025-01-01 03:00:15,27,https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt,failed
2025-01-02 03:00:18,27,https://osint.digitalside.it/Threat-Intel/lists/latestdomains.txt,failed
```

## Re-enabling Disabled Adlists

If an adlist comes back online, you can re-enable it through the Pi-hole web interface:

1. Go to **Group Management** → **Adlists**
2. Find the disabled list (shows as "Disabled")
3. Click the toggle to re-enable
4. Run `pihole -g` to update gravity

The script will start tracking it again if it fails in the future.

## Notifications (Optional)

The script includes a `send_notification()` function stub. You can customize it to integrate with your notification system:

### Example: Email Notification

```bash
send_notification() {
    local id=$1
    local url=$2
    local failure_count=$3
    
    echo "Adlist ID $id has been disabled after $failure_count failures: $url" | \
    mail -s "Pi-hole: Adlist Auto-Disabled" your-email@example.com
}
```

### Example: Pushover Notification

```bash
send_notification() {
    local id=$1
    local url=$2
    local failure_count=$3
    
    curl -s \
      --form-string "token=YOUR_APP_TOKEN" \
      --form-string "user=YOUR_USER_KEY" \
      --form-string "message=Adlist ID $id disabled after $failure_count failures" \
      https://api.pushover.net/1/messages.json
}
```

## Troubleshooting

### Script Not Finding Failures

**Problem**: Script reports no failures even though gravity shows errors

**Solution**: Check if Pi-hole logs are in a different location:
```bash
# Find your Pi-hole log location
ls -la /var/log/pihole/

# Update the log_file variable in parse_gravity_log() function if needed
```

### Permission Errors

**Problem**: Script can't write to log directory

**Solution**: Ensure the script runs as root via cron or sudo:
```bash
sudo chmod +x /usr/local/bin/pihole-adlist-cleanup.sh
sudo chown root:root /usr/local/bin/pihole-adlist-cleanup.sh
```

### Database Locked Errors

**Problem**: SQLite database busy/locked errors

**Solution**: Ensure the script doesn't run simultaneously with gravity:
```bash
# Add a lock file check at the beginning of main()
if [[ -f /var/lock/pihole-cleanup.lock ]]; then
    exit 0
fi
touch /var/lock/pihole-cleanup.lock
# ... rest of script
rm /var/lock/pihole-cleanup.lock
```

## Maintenance

### Regular Checks

Periodically review the statistics:
```bash
sudo /usr/local/bin/pihole-adlist-cleanup.sh --stats
```

### Log Rotation

Add log rotation to prevent logs from growing too large:

Create `/etc/logrotate.d/pihole-cleanup`:
```
/var/log/pihole-cleanup/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
```

## Example Workflow

1. **Initial Setup**: Install script, run `--dry-run` to verify behavior
2. **Monitor**: Run `--stats` weekly to see which lists are problematic
3. **Adjust**: If needed, modify `FAILURE_THRESHOLD` or `DAYS_WINDOW`
4. **Automated**: Let cron handle daily checks
5. **Review**: Occasionally check cleanup logs for disabled lists
6. **Update**: Replace disabled lists with alternatives or re-enable when fixed

## Uninstallation

```bash
# Remove cron job
sudo crontab -e  # Delete the pihole-adlist-cleanup line

# Remove script
sudo rm /usr/local/bin/pihole-adlist-cleanup.sh

# Optionally remove logs
sudo rm -rf /var/log/pihole-cleanup
```

## Support

For issues specific to:
- **Pi-hole**: Check Pi-hole documentation or forums
- **This script**: Review logs in `/var/log/pihole-cleanup/`
- **Adlist sources**: Check the source's GitHub/website for status

## Version History

- **v1.0**: Initial release
  - Automatic failure tracking
  - Configurable thresholds
  - Dry-run mode
  - Statistics reporting

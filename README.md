# Pi-hole Adlist Auto-Cleanup

Automated monitoring and cleanup script for Pi-hole that tracks gravity update failures and automatically disables adlists that consistently fail to load.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Pi-hole](https://img.shields.io/badge/Pi--hole-Compatible-96060C.svg)](https://pi-hole.net/)

## Overview

Pi-hole is an excellent network-wide ad blocker, but adlist sources can become unavailable over time due to server downtime, domain expiration, or project abandonment. This script automatically monitors your Pi-hole's gravity update failures and disables adlists that repeatedly fail, keeping your Pi-hole configuration clean and your gravity updates running smoothly.

**Problem it solves:** Manually tracking which adlists are broken and removing them from your Pi-hole configuration is tedious. This script automates the entire process.

## Features

- ✅ **Automatic Failure Tracking** - Monitors gravity logs for inaccessible adlists
- ✅ **Configurable Thresholds** - Default: 10 failures over 30 days (fully customizable)
- ✅ **Safe Operation** - Disables problematic lists rather than deleting them
- ✅ **Detailed Logging** - Maintains comprehensive failure history
- ✅ **Dry-Run Mode** - Test the script without making changes
- ✅ **Statistics Reporting** - View failure trends and identify problem lists
- ✅ **Automatic Cleanup** - Removes old failure records to prevent log bloat
- ✅ **Easy Re-enabling** - Disabled lists can be quickly re-enabled if they come back online
- ✅ **Notification Ready** - Includes hooks for email, Pushover, or other notification systems

## Quick Start

### Installation

```bash
# Download the script
wget https://raw.githubusercontent.com/DorkPirate/pihole-adlist-cleanup/main/pihole-adlist-cleanup.sh -O /tmp/pihole-adlist-cleanup.sh

# Install it
sudo mv /tmp/pihole-adlist-cleanup.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/pihole-adlist-cleanup.sh

# Test it (dry-run mode - no changes made)
sudo /usr/local/bin/pihole-adlist-cleanup.sh --dry-run
```

### Automate It

Add to crontab to run daily at 3 AM (after gravity typically runs):

```bash
sudo crontab -e
```

Add this line:

```
0 3 * * * /usr/local/bin/pihole-adlist-cleanup.sh
```

## Usage

### Basic Commands

```bash
# Run the cleanup check manually
sudo /usr/local/bin/pihole-adlist-cleanup.sh

# Test without making changes (dry-run mode)
sudo /usr/local/bin/pihole-adlist-cleanup.sh --dry-run

# View failure statistics
sudo /usr/local/bin/pihole-adlist-cleanup.sh --stats

# Reset failure tracking log
sudo /usr/local/bin/pihole-adlist-cleanup.sh --reset

# Show help
sudo /usr/local/bin/pihole-adlist-cleanup.sh --help
```

### Example Statistics Output

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

## How It Works

1. **Detection** - Script parses Pi-hole logs for "was inaccessible during last gravity run" messages
2. **Recording** - Each failure is logged with timestamp, adlist ID, and URL
3. **Counting** - Tracks failures for each adlist within the configured time window
4. **Action** - When threshold is exceeded, the adlist is disabled (not deleted)
5. **Notification** - Logs the action to `/var/log/pihole-cleanup/cleanup.log`
6. **Cleanup** - Removes failure records older than the time window + 7 days

## Configuration

Edit these variables at the top of the script to customize behavior:

```bash
FAILURE_THRESHOLD=10        # Number of failures before removal
DAYS_WINDOW=30              # Time window to track failures (days)
LOG_DIR="/var/log/pihole-cleanup"
```

### Configuration Examples

**More Aggressive** (remove faster):
```bash
FAILURE_THRESHOLD=5
DAYS_WINDOW=14
```

**More Lenient** (give more chances):
```bash
FAILURE_THRESHOLD=20
DAYS_WINDOW=60
```

## Logs

The script maintains two log files in `/var/log/pihole-cleanup/`:

### Cleanup Log (`cleanup.log`)
General script execution and actions taken:
```
[2025-01-01 03:00:15] [INFO] Starting Pi-hole Adlist Cleanup Check
[2025-01-01 03:00:16] [WARNING] Disabled adlist ID 27 after 10 failures
```

### Failure Log (`adlist_failures.log`)
CSV format tracking all failures:
```
timestamp,adlist_id,address,status
2025-01-01 03:00:15,27,https://osint.digitalside.it/...,failed
```

## Re-enabling Adlists

If a previously disabled adlist comes back online:

1. Go to **Pi-hole Web Interface** → **Group Management** → **Adlists**
2. Find the disabled list (shows as "Disabled")
3. Click the toggle to re-enable
4. Run `pihole -g` to update gravity

The script will continue monitoring it and track new failures if they occur.

## Notifications (Optional)

The script includes a `send_notification()` function that you can customize. Examples:

### Email Notification

```bash
send_notification() {
    local id=$1
    local url=$2
    local failure_count=$3
    
    echo "Adlist ID $id has been disabled after $failure_count failures: $url" | \
    mail -s "Pi-hole: Adlist Auto-Disabled" your-email@example.com
}
```

### Pushover Notification

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

## Requirements

- Pi-hole v5.0 or later
- Bash 4.0+
- SQLite3 (included with Pi-hole)
- Root/sudo access

## Compatibility

Tested on:
- Raspberry Pi OS (Debian-based)
- Ubuntu Server
- Docker Pi-hole installations

Should work on any Linux system running Pi-hole.

## Documentation

For detailed installation instructions, troubleshooting, and advanced configuration, see the [Installation Guide](INSTALLATION_GUIDE.md).

## Troubleshooting

### Script reports no failures but gravity shows errors

Check if Pi-hole logs are in a different location:
```bash
ls -la /var/log/pihole/
```

Update the `log_file` variable in the `parse_gravity_log()` function if needed.

### Permission errors

Ensure the script runs as root:
```bash
sudo chmod +x /usr/local/bin/pihole-adlist-cleanup.sh
sudo chown root:root /usr/local/bin/pihole-adlist-cleanup.sh
```

### View detailed logs

```bash
# Watch cleanup log in real-time
sudo tail -f /var/log/pihole-cleanup/cleanup.log

# View failure tracking
sudo cat /var/log/pihole-cleanup/adlist_failures.log
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development

```bash
# Clone the repository
git clone https://github.com/DorkPirate/pihole-adlist-cleanup.git
cd pihole-adlist-cleanup

# Make your changes
# Test with dry-run mode
sudo ./pihole-adlist-cleanup.sh --dry-run

# Submit a PR
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Author

**Matt** - Systems Engineer & Security Specialist
- Rite-Solutions (NUWC Contracts)
- 20-year Navy veteran specializing in submarine communications and cybersecurity
- CompTIA SecurityX certified

## Acknowledgments

- Pi-hole team for creating an excellent network-wide ad blocker
- The open-source community maintaining adlist sources
- Inspired by the need to automate maintenance of my home network infrastructure

## Support

- **Issues**: [GitHub Issues](https://github.com/DorkPirate/pihole-adlist-cleanup/issues)
- **Discussions**: [GitHub Discussions](https://github.com/DorkPirate/pihole-adlist-cleanup/discussions)
- **Pi-hole Documentation**: [https://docs.pi-hole.net/](https://docs.pi-hole.net/)

## Changelog

### v1.0.0 (2026-01-01)
- Initial release
- Automatic failure tracking
- Configurable thresholds (10 failures over 30 days default)
- Dry-run mode for safe testing
- Statistics reporting
- Comprehensive logging
- Old record cleanup

## Roadmap

- [ ] Add email notification integration
- [ ] Create web dashboard for failure statistics
- [ ] Add support for automatic adlist replacement suggestions
- [ ] Integration with Pi-hole Telegram Bot
- [ ] Backup/restore functionality for adlist configurations
- [ ] Support for custom failure patterns

---

**Star this repository** if you find it useful! ⭐

**Found a bug?** Please open an [issue](https://github.com/DorkPirate/pihole-adlist-cleanup/issues).

**Want to contribute?** Pull requests are welcome!

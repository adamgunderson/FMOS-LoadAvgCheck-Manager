# FMOS LoadAvgCheck Manager

A bash utility script for FireMon OS (FMOS) that automatically manages the LoadAvgCheck health check during backup operations to prevent false alerts caused by high system load during backups.

## Overview

During FMOS backup operations, system load can spike significantly, triggering the LoadAvgCheck health monitor and generating unnecessary alerts. This script automatically disables the LoadAvgCheck before backups begin and re-enables it after completion, ensuring clean backup operations without false positive health alerts.
## Features

- **Automatic Check Management**: Disables LoadAvgCheck before backups, re-enables after completion
- **Load Settling Delay**: Waits 15 minutes after backup before re-enabling to prevent false alerts (can be bypassed with `--no-wait`)
- **Dual Configuration Methods**:
  - **fmos config (default)**: Uses native `fmos config` commands - no credentials needed!
  - **API (alternative)**: Uses FMOS Control Panel API - requires credentials but useful in some scenarios
- **No Credentials Required (default)**: Uses `fmos config` commands with automatic user switching when run as root
- **Simple Architecture**: Script runs directly from wherever you place it - no complexity!
- **Smart Cronjob Sync**: Automatically detects backup schedule changes and updates cronjob timing
- **Post-Backup Hooks**: Configures FMOS post-backup scripts for automatic re-enable
- **Flexible Logging**: Optional logging with control over verbosity
- **Status Monitoring**: View current configuration and check status with schedule validation
- **Safe Configuration**: Uses `jq` for safe JSON manipulation without overwriting other settings
- **Immediate Updates**: Changes to the script take effect immediately

## Requirements

- FMOS virtual appliance with admin user access
- `jq` installed (for JSON processing, standard on FMOS)
- `curl` installed (only needed for `--use-api` mode, standard on FMOS)
- Bash shell (standard on FMOS)
- FMOS Control Panel API credentials (only if using `--use-api` flag)
- No root/sudo access required

## Installation

**On FireMon OS, install to `/var/lib/backup/firemon/` to avoid SELinux issues:**

```bash
# Download the script to the backup directory (avoids SELinux issues)
cd /var/lib/backup/firemon
wget -O manage_loadavg_check.sh https://raw.githubusercontent.com/adamgunderson/FMOS-LoadAvgCheck-Manager/main/manage_loadavg_check.sh

# Set proper permissions
chmod 755 manage_loadavg_check.sh

# Verify installation
bash ./manage_loadavg_check.sh status
```

**Important Notes:**
- **Installation Location**: Use `/var/lib/backup/firemon/` on FireMon OS - this directory has the proper SELinux context (`firemon_backup_t`) that allows root to execute scripts during post-backup operations.
- **Why not home directory?** SELinux in enforcing mode prevents root from executing scripts from user home directories (`user_home_t` context), causing "Permission denied" errors during post-backup execution.

### Manual Installation

1. Copy `manage_loadavg_check.sh` to your FMOS system
2. Save it to `/var/lib/backup/firemon/` directory (proper SELinux context for FMOS)
3. Set proper permissions:
   ```bash
   chmod 755 /var/lib/backup/firemon/manage_loadavg_check.sh
   ```

## Quick Start

```bash
# Navigate to the backup directory (proper SELinux context for FMOS)
cd /var/lib/backup/firemon

# Run the automatic setup (no credentials needed with default method)
bash ./manage_loadavg_check.sh setup

# Verify the configuration
bash ./manage_loadavg_check.sh status
```

**What setup does:**
1. Configure a cronjob to disable LoadAvgCheck 5 minutes before backup
2. Set up post-backup scripts to re-enable the check after backup completion
3. Show the current configuration status
4. **(Optional)** Prompt for and securely store FMOS Control Panel API credentials (only if using `--use-api` flag)

**Configuration Methods:**
- **Default (fmos config)**: Uses `fmos config` commands - no credentials needed
- **Alternative (API)**: Add `--use-api` flag to use FMOS Control Panel API - requires credentials

**Note about SELinux:** If you encounter permission errors during post-backup execution, SELinux may be blocking script execution. See the [Troubleshooting](#post-backup-action-failures) section.

## Usage

### Basic Commands

```bash
# On FireMon OS, the script should be in /var/lib/backup/firemon/
cd /var/lib/backup/firemon

# Show help and usage information
bash ./manage_loadavg_check.sh

# Manually disable the LoadAvgCheck
bash ./manage_loadavg_check.sh disable

# Manually enable the LoadAvgCheck (waits 15 minutes by default)
bash ./manage_loadavg_check.sh enable

# Enable LoadAvgCheck immediately without waiting
bash ./manage_loadavg_check.sh enable --no-wait

# Run full automatic setup
bash ./manage_loadavg_check.sh setup

# Remove all configurations and cleanup
bash ./manage_loadavg_check.sh cleanup

# Show current status and configuration
bash ./manage_loadavg_check.sh status

# Update stored API credentials (only needed for --use-api mode)
bash ./manage_loadavg_check.sh credentials

# Toggle logging on/off
bash ./manage_loadavg_check.sh logging on   # Enable logging
bash ./manage_loadavg_check.sh logging off  # Disable logging
```

### Configuration Methods

The script supports two configuration methods:

#### Method 1: fmos config (Default - Recommended)

**No credentials required!** Uses native `fmos config` commands:

```bash
# Standard usage (no credentials needed)
cd /var/lib/backup/firemon
bash ./manage_loadavg_check.sh setup

# The script automatically switches to the admin user when run as root
# No API credentials or manual configuration needed
```

#### Method 2: API (Alternative)

Uses the FMOS Control Panel API - requires credentials:

```bash
# Use API method during setup
cd /var/lib/backup/firemon
bash ./manage_loadavg_check.sh --use-api setup

# Or set environment variable
CONFIG_METHOD=api bash ./manage_loadavg_check.sh setup

# To update credentials later
bash ./manage_loadavg_check.sh --use-api credentials

# Credentials are stored in: ~/.fmos_api_creds (user home directory)
# File permissions: 644 (readable by all, writable by owner - allows root to read during post-backup)
# Storage: Base64 encoded (obfuscated, not encrypted)
```

**API Method - Alternative with Environment Variables:**
```bash
# Set credentials via environment (takes priority over stored file)
export FMOS_API_USER=firemon
export FMOS_API_PASS='your_password'

cd /var/lib/backup/firemon
bash ./manage_loadavg_check.sh --use-api enable
```

**When to use API method:**
- When `fmos config` commands are not available or restricted
- When you prefer API-based configuration management
- For compatibility with older setups that used the API method

### Logging Options

Control logging behavior for debugging or production use:

```bash
# Navigate to script location
cd /var/lib/backup/firemon

# Run any command without logging (one-time)
bash ./manage_loadavg_check.sh --no-log setup

# Use environment variable (alternative method)
NO_LOG=1 bash ./manage_loadavg_check.sh disable

# Permanently disable logging for all automated runs
bash ./manage_loadavg_check.sh logging off

# Re-enable logging
bash ./manage_loadavg_check.sh logging on
```

### Wait Control Options

Control the 15-minute wait when re-enabling the health check:

```bash
# Navigate to script location
cd /var/lib/backup/firemon

# Enable with default 15 minute wait (recommended after backups)
bash ./manage_loadavg_check.sh enable

# Enable immediately without waiting (use if manually re-enabling)
bash ./manage_loadavg_check.sh enable --no-wait

# Use environment variable (alternative method)
NO_WAIT=1 bash ./manage_loadavg_check.sh enable

# Combine flags
bash ./manage_loadavg_check.sh enable --no-wait --no-log
```

**When to use `--no-wait`:**
- When manually re-enabling the check outside of backup operations
- When you know the system load has already settled
- When testing or troubleshooting the script

**When NOT to use `--no-wait`:**
- During the automated post-backup process (default behavior is correct)
- Immediately after a backup completes (let the 15-minute wait run)

## How It Works

### Backup Schedule Detection

The script automatically detects your FMOS backup schedule:
- Reads configuration from `fmos config get os/backup/auto-backup`
- Uses default time (23:48) if no custom schedule is configured
- Calculates pre-backup time (5 minutes before backup)

### Configuration Flow

1. **Setup Phase**
   - Prompts for API credentials (if not already stored)
   - Validates credentials against FMOS Control Panel API
   - Configures cronjob for pre-backup disable
   - Configures post-backup hook

2. **Pre-Backup (Cronjob)**
   - Runs 5 minutes before scheduled backup
   - Uses configured method (default: `fmos config`, alternative: API) to add `fmos.health.checks.basic.LoadAvgCheck` to ignore list
   - Applies configuration changes

3. **Post-Backup (Hook)**
   - Triggered automatically by FMOS after backup completion (runs as root)
   - Executes `/bin/bash /home/admin/manage_loadavg_check.sh enable`
   - Uses `/usr/bin/env` to set environment variables when logging control is needed
   - **Waits 15 minutes** for backup load average to settle before re-enabling
   - Script uses configured method (default: `fmos config` with automatic user switching, alternative: API with stored credentials)
   - Removes LoadAvgCheck from ignore list
   - Runs on both backup success and failure

### File Locations

- **Script**: `/var/lib/backup/firemon/manage_loadavg_check.sh` (proper SELinux context)
- **Credentials**: `/home/<user>/.fmos_api_creds` (base64 encoded, 644 permissions, only if using `--use-api`)
- **Log File**: `/var/tmp/loadavg_check_manager.log` (auto-rotates at 1MB, keeps last 500 lines)
- **Cronjob**: User's crontab
- **FMOS Config** (via `fmos config` commands or API):
  - `os/health` - Health check ignore list
  - `os/backup/post-backup` - Post-backup script hooks (executed by backup system as root)

**Note**: The script runs directly from `/var/lib/backup/firemon/`. Updates take effect immediately with no sync needed.

**Configuration Method**: Defaults to using `fmos config` commands (no credentials needed). Use `--use-api` flag to use the API method instead.

## Status Output Example

```
=== LoadAvgCheck Manager Status ===

Configuration Method:
  Method: fmos_config
  Description: Using 'fmos config' commands (default, no credentials needed)

Health Check Status:
  ✓ fmos.health.checks.basic.LoadAvgCheck is currently ENABLED

Script Location:
  /home/admin/manage_loadavg_check.sh

API Authentication:
  No credentials configured

Backup Schedule:
  Enabled: true
  Schedule: daily at 23:48

Cronjob Status:
  43 23 * * * /bin/bash /home/admin/manage_loadavg_check.sh disable >/dev/null 2>&1

Post-backup Configuration:
  ✓ Post-backup script configured

Logging:
  Logging to: /var/tmp/loadavg_check_manager.log
  Log size: 4.0K
```

## Troubleshooting

### Post-Backup Action Failures

#### Error: "No such file or directory: 'NO_LOG=0'"

If you see this error in backup logs, it means you have an older version of the script that doesn't use `/usr/bin/env` to set environment variables.

**The Fix:**
```bash
# Update to the latest version of the script
# Then re-run setup to update the post-backup configuration
bash /home/admin/manage_loadavg_check.sh setup
```

The latest version uses `/usr/bin/env` to properly set environment variables for the FMOS backup system.

#### Error: "/bin/bash: /home/admin/manage_loadavg_check.sh: Permission denied"

This is the most common error. The issue is **SELinux** - it prevents root from executing scripts in user home directories.

**The Root Cause:**
- SELinux is in **Enforcing** mode on FireMon OS
- Scripts in home directories have `user_home_t` SELinux context
- Root cannot execute files with this context during post-backup operations
- File permissions (755) are not enough when SELinux is enforcing

**The Fix - Move to Proper Location:**
```bash
# Move script to a location with proper SELinux context
cd /var/lib/backup/firemon
cp ~/manage_loadavg_check.sh ./
chmod 755 ./manage_loadavg_check.sh

# Re-run setup from the new location (IMPORTANT!)
bash ./manage_loadavg_check.sh setup

# This will reconfigure the post-backup hook to use the new path
# Test the backup
fmos backup
```

**Why `/var/lib/backup/firemon/` works:**
- Has `firemon_backup_t` SELinux context (not `user_home_t`)
- Root can execute scripts from this location
- Won't be cleaned up on reboot (unlike /tmp)
- Logically related to backup operations

#### Understanding SELinux on FireMon OS

FireMon OS runs SELinux in **Enforcing** mode. This is a security feature that prevents certain operations even with correct file permissions.

**Check SELinux status and context:**
```bash
# Check if SELinux is enforcing (it is on FMOS)
getenforce
# Output: Enforcing

# Check the SELinux context of your script
ls -Z ~/manage_loadavg_check.sh
# Output: unconfined_u:object_r:user_home_t:s0  <- This is the problem!

# Check a working location
ls -Z /var/lib/backup/firemon/manage_loadavg_check.sh
# Output: unconfined_u:object_r:firemon_backup_t:s0  <- This works!
```

**Why you can't use chcon or setenforce on FMOS:**
- FMOS is a virtual appliance with restricted admin access
- No `sudo` or root access available to regular users
- Cannot modify SELinux policies or change contexts
- Cannot set SELinux to permissive mode

**The only solution:** Install the script in `/var/lib/backup/firemon/` which has the correct SELinux context by default.

#### Error: "Post-backup action failed" (Permission Denied - API Related)

If you see "Post-backup action failed" errors related to permissions:

**The Solution:**
The script now uses the FMOS Control Panel API instead of CLI commands, which completely eliminates permission issues!

**Verify Configuration:**
```bash
# Check that credentials are stored
bash /home/admin/manage_loadavg_check.sh status
# Should show: "Stored credentials: ✓ (user: adam)"

# Verify credentials file permissions (should be 644)
ls -la ~/.fmos_api_creds

# Test API authentication manually
bash /home/admin/manage_loadavg_check.sh enable --no-wait
bash /home/admin/manage_loadavg_check.sh disable

# Check post-backup configuration via API
curl -k -s \
  -H "Cookie: $(cat ~/.fmos_api_creds | head -1 | base64 -d)" \
  "https://localhost:55555/api/config/values/os%2Fbackup%2Fpost-backup"
```

**Update Credentials:**
```bash
# If credentials are wrong or expired
cd /var/lib/backup/firemon
bash ./manage_loadavg_check.sh credentials

# Re-run setup to update both credentials and post-backup config
bash ./manage_loadavg_check.sh setup
```

### Creating Convenience Aliases

For easier access to the script:

```bash
# Create an alias to run the script from anywhere
echo "alias loadavg-manager='cd /var/lib/backup/firemon && bash ./manage_loadavg_check.sh'" >> ~/.bashrc
source ~/.bashrc

# Now you can run commands from anywhere:
loadavg-manager status
loadavg-manager enable --no-wait
loadavg-manager disable
```


### Automatic Cronjob Synchronization

The script automatically detects when the backup schedule has changed and updates the cronjob accordingly:

```bash
# The cronjob is automatically checked and updated during:
# - enable operations (post-backup)
# - disable operations (pre-backup via cron)
# - status checks (displays warning if out of sync)

# Example: You change backup from 23:48 to 02:00
# Next time the script runs (enable/disable), you'll see:
⚠ Backup schedule has changed!
  Backup is now at: 02:00
  Cronjob updated to: 01:55

# Or when running status:
Cronjob Status:
  43 23 * * * /bin/bash /var/lib/backup/firemon/manage_loadavg_check.sh disable >/dev/null 2>&1

  ⚠ WARNING: Cronjob schedule is out of sync!
  Current cronjob: 23:43
  Should be:       01:55 (5 min before backup at 02:00)
  Run: cd /var/lib/backup/firemon && bash ./manage_loadavg_check.sh enable
```

**How it works:**
1. Every time `enable` or `disable` runs, it queries the current backup schedule via API
2. Compares it with the current cronjob schedule
3. If different, automatically updates the cronjob to run 5 minutes before the new backup time
4. Logs the change and notifies you

This means you can change the backup schedule in the FMOS UI and the script will automatically adapt!

### Verify Check is Being Disabled

```bash
# Check current ignore list via API
curl -k -s -H "Cookie: ..." "https://localhost:55555/api/config/values/os%2Fhealth" | jq '.health.ignore_checks'

# Monitor the log file (if logging enabled)
tail -f ~/loadavg_check_manager.log
```

### Manual Recovery

If automatic re-enable fails:

```bash
# Navigate to script location
cd /var/lib/backup/firemon

# Manually re-enable the check (waits 15 minutes)
bash ./manage_loadavg_check.sh enable

# Or re-enable immediately without waiting
bash ./manage_loadavg_check.sh enable --no-wait

# Verify it's enabled
bash ./manage_loadavg_check.sh status
```

### Complete Removal

To completely remove all configurations:

```bash
# Navigate to script location
cd /var/lib/backup/firemon

# Remove all setup and re-enable checks
# This removes:
#   - Pre-backup cronjob
#   - Post-backup hook configuration
#   - Stored API credentials
#   - Re-enables LoadAvgCheck
bash ./manage_loadavg_check.sh cleanup

# Optionally remove the script and logs
rm -f /var/lib/backup/firemon/manage_loadavg_check.sh
rm -f ~/loadavg_check_manager.log
rm -f ~/.fmos_api_creds
```

## Security Considerations

- Designed for FMOS virtual appliance (no root/sudo access required)
- Script uses explicit `/bin/bash` interpreter to work when executed by backup system (root)
- **Script permissions**: Script file must be 755 (rwxr-xr-x) to allow root to read/execute during post-backup
- **SELinux requirements**: Must be installed to `/var/lib/backup/firemon/` on FMOS to work with SELinux enforcing mode
- **Configuration methods**:
  - **fmos config (default)**: Uses native commands, automatically switches to admin user when run as root, no credentials needed
  - **API (alternative)**: Uses FMOS Control Panel API (`https://localhost:55555/api`), requires credentials
- **Credential storage (API method only)**: Base64 encoded in `.fmos_api_creds` with 644 permissions (readable by all, writable by owner only)
- **Portable design**: Dynamically detects admin username - no hardcoded values
- **Log rotation**: Automatic rotation at 1MB, keeps last 500 lines to prevent disk space issues
- All operations logged for audit purposes (when logging enabled) to `/var/tmp/loadavg_check_manager.log`
- No direct system file modifications - all changes via `fmos config` commands or API
- Cronjob runs with admin user privileges
- **Simple architecture**: Script runs from `/var/lib/backup/firemon/` on FMOS - no temporary copies needed

## Support

For issues or questions:
1. Check the log file: `cat ~/loadavg_check_manager.log`
2. Verify FMOS backup configuration: `fmos config get os/backup/auto-backup`
3. Check health configuration: `fmos config get os/health`
4. Run status command: `cd /var/lib/backup/firemon && bash ./manage_loadavg_check.sh status`

## License

This script is provided as-is for use with FMOS systems. Modify as needed for your environment.

## Contributing

Improvements and bug fixes are welcome. Please test thoroughly in a non-production environment before deploying to production FMOS systems.

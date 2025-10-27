# FMOS LoadAvgCheck Manager

A utility script for FireMon OS (FMOS) that automatically manages the LoadAvgCheck health check during backup operations to prevent false alerts caused by high system load during backups.

## Overview

During FMOS backup operations, system load can spike significantly, triggering the LoadAvgCheck health monitor and generating unnecessary alerts. This script automatically disables the LoadAvgCheck before backups begin and re-enables it after completion, ensuring clean backup operations without false positive health alerts.

## Version Comparison

This project provides **two versions** of the script:

### 🐍 Python Version (Recommended)
**File:** `manage_loadavg_check.py`

**Advantages:**
- ✅ **No SELinux issues** - Python executables have proper security contexts by default
- ✅ **No file permission problems** - Works reliably across user boundaries
- ✅ **Better error handling** - More informative error messages
- ✅ **Native JSON support** - No external dependencies like `jq`
- ✅ **Cleaner code** - Easier to maintain and extend
- ✅ **Built-in HTTP client** - Uses `requests` library

**Requirements:** Python 3.6+ and `requests` module

### 🐚 Bash Version (Legacy)
**File:** `manage_loadavg_check.sh`

**Advantages:**
- ✅ No Python dependencies
- ✅ Familiar bash syntax

**Limitations:**
- ⚠️ Can have SELinux permission issues when running from home directory
- ⚠️ Requires specific file permissions (755) and proper security contexts
- ⚠️ Requires `jq` for JSON processing
- ⚠️ More complex environment variable handling

**Recommendation:** Use the Python version unless you have specific requirements for bash. The Python version eliminates most permission and SELinux issues.

## Features

- **Automatic Check Management**: Disables LoadAvgCheck before backups, re-enables after completion
- **Load Settling Delay**: Waits 15 minutes after backup before re-enabling to prevent false alerts (can be bypassed with `--no-wait`)
- **API-Based Configuration**: Uses FMOS Control Panel API via curl (no CLI permission issues!)
- **Secure Credential Storage**: Prompts for credentials during setup, stores them securely with 644 permissions
- **Simple Architecture**: Script runs directly from wherever you place it - no complexity!
- **Smart Cronjob Sync**: Automatically detects backup schedule changes and updates cronjob timing
- **Post-Backup Hooks**: Configures FMOS post-backup scripts for automatic re-enable
- **Flexible Logging**: Optional logging with control over verbosity
- **Status Monitoring**: View current configuration and check status with schedule validation
- **Safe Configuration**: Uses `jq` for safe JSON manipulation without overwriting other settings
- **Immediate Updates**: Changes to the script take effect immediately

## Requirements

### Python Version (Recommended)
- FMOS virtual appliance with admin user access
- Python 3.6 or higher (standard on FMOS)
- Python `requests` module: `pip3 install requests`
- FMOS Control Panel API credentials
- No root/sudo access required

### Bash Version (Legacy)
- FMOS virtual appliance with admin user access
- `jq` installed (for JSON processing)
- `curl` installed (for API calls)
- Bash shell (standard on FMOS)
- FMOS Control Panel API credentials
- No root/sudo access required

## Installation

### Python Version (Recommended)

```bash
# Download the Python script
wget -O ~/manage_loadavg_check.py https://raw.githubusercontent.com/adamgunderson/FMOS-LoadAvgCheck-Manager/main/manage_loadavg_check.py

# Make it executable
chmod +x ~/manage_loadavg_check.py

# Install Python requests module (if not already installed)
pip3 install requests

# Verify installation
python3 ~/manage_loadavg_check.py status
```

### Bash Version (Legacy)

```bash
# Download the bash script
wget -O ~/manage_loadavg_check.sh https://raw.githubusercontent.com/adamgunderson/FMOS-LoadAvgCheck-Manager/main/manage_loadavg_check.sh

# Set proper permissions (readable and executable by all, writable by owner)
chmod 755 ~/manage_loadavg_check.sh

# Verify installation
bash ~/manage_loadavg_check.sh status
```

### Manual Installation

#### Python Version
1. Copy `manage_loadavg_check.py` to your FMOS system
2. Save it to your home directory
3. Make it executable: `chmod +x ~/manage_loadavg_check.py`
4. Install requests: `pip3 install requests`

#### Bash Version
1. Copy `manage_loadavg_check.sh` to your FMOS system
2. Save it to your home directory
3. Set proper permissions: `chmod 755 ~/manage_loadavg_check.sh`

   **Important**: The bash script must be readable by root for post-backup execution to work!

## Quick Start

### Python Version (Recommended)

```bash
# Run the automatic setup (will prompt for API credentials)
python3 ~/manage_loadavg_check.py setup

# You will be prompted for:
# - Username (defaults to your current user)
# - Password (hidden input)
# - Password confirmation

# Verify the configuration
python3 ~/manage_loadavg_check.py status
```

### Bash Version

```bash
# Run the automatic setup (will prompt for API credentials)
bash ~/manage_loadavg_check.sh setup

# Verify the configuration
bash ~/manage_loadavg_check.sh status
```

**What setup does:**
1. Prompt for and securely store FMOS Control Panel API credentials
2. Configure a cronjob to disable LoadAvgCheck 5 minutes before backup
3. Set up post-backup scripts to re-enable the check after backup completion
4. Show the current configuration status

**Note about SELinux (Bash version only):** If using the bash version and you encounter permission errors during post-backup execution, SELinux may be blocking cross-user script execution. See the [Troubleshooting](#post-backup-action-failures) section. **The Python version does not have this issue.**

## Usage

### Basic Commands

#### Python Version (Recommended)

```bash
# Show help and usage information
python3 ~/manage_loadavg_check.py --help

# Manually disable the LoadAvgCheck
python3 ~/manage_loadavg_check.py disable

# Manually enable the LoadAvgCheck (waits 15 minutes by default)
python3 ~/manage_loadavg_check.py enable

# Enable LoadAvgCheck immediately without waiting
python3 ~/manage_loadavg_check.py enable --no-wait

# Run full automatic setup
python3 ~/manage_loadavg_check.py setup

# Remove all configurations and cleanup
python3 ~/manage_loadavg_check.py cleanup

# Show current status and configuration
python3 ~/manage_loadavg_check.py status

# Update stored API credentials
python3 ~/manage_loadavg_check.py credentials
```

#### Bash Version

```bash
# Show help and usage information
bash ~/manage_loadavg_check.sh

# All the same commands work with bash script
bash ~/manage_loadavg_check.sh disable
bash ~/manage_loadavg_check.sh enable --no-wait
bash ~/manage_loadavg_check.sh setup
bash ~/manage_loadavg_check.sh status

# Additional bash-specific commands
bash ~/manage_loadavg_check.sh logging on   # Toggle logging on
bash ~/manage_loadavg_check.sh logging off  # Toggle logging off
```

### Credential Management

The script uses the FMOS Control Panel API and requires credentials:

```bash
# During setup, you'll be prompted for credentials
bash ~/manage_loadavg_check.sh setup

# To update credentials later
bash ~/manage_loadavg_check.sh credentials

# Credentials are stored in: ~/.fmos_api_creds (or script directory)
# File permissions: 644 (readable by all, writable by owner - allows root to read during post-backup)
# Storage: Base64 encoded (obfuscated, not encrypted)
```

**Alternative: Environment Variables**
```bash
# Set credentials via environment (takes priority over stored file)
export FMOS_API_USER=adam
export FMOS_API_PASS='your_password'

bash ~/manage_loadavg_check.sh enable
```

### Logging Options

Control logging behavior for debugging or production use:

```bash
# Run any command without logging (one-time)
bash ~/manage_loadavg_check.sh --no-log setup

# Use environment variable (alternative method)
NO_LOG=1 bash ~/manage_loadavg_check.sh disable

# Permanently disable logging for all automated runs
bash ~/manage_loadavg_check.sh logging off

# Re-enable logging
bash ~/manage_loadavg_check.sh logging on
```

### Wait Control Options

Control the 15-minute wait when re-enabling the health check:

```bash
# Enable with default 15 minute wait (recommended after backups)
bash ~/manage_loadavg_check.sh enable

# Enable immediately without waiting (use if manually re-enabling)
bash ~/manage_loadavg_check.sh enable --no-wait

# Use environment variable (alternative method)
NO_WAIT=1 bash ~/manage_loadavg_check.sh enable

# Combine flags
bash ~/manage_loadavg_check.sh enable --no-wait --no-log
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
   - Calls API to add `fmos.health.checks.basic.LoadAvgCheck` to ignore list
   - Applies configuration changes via API

3. **Post-Backup (Hook)**
   - Triggered automatically by FMOS after backup completion (runs as root)
   - Executes `/bin/bash /home/admin/manage_loadavg_check.sh enable`
   - Uses `/usr/bin/env` to set environment variables when logging control is needed
   - **Waits 15 minutes** for backup load average to settle before re-enabling
   - Script uses stored API credentials to authenticate
   - Calls API to remove LoadAvgCheck from ignore list
   - Runs on both backup success and failure

### File Locations

- **Script**: `/home/admin/manage_loadavg_check.sh` (or wherever you place it)
- **Credentials**: `/home/admin/.fmos_api_creds` (base64 encoded, 644 permissions)
- **Log File**: `/home/admin/loadavg_check_manager.log` (located in same directory as script)
- **Cronjob**: Admin user's crontab
- **FMOS Config** (via API):
  - `os/health` - Health check ignore list
  - `os/backup/post-backup` - Post-backup script hooks (executed by backup system as root)

**Note**: The script runs directly from wherever you place it. Updates take effect immediately with no sync needed.

## Status Output Example

```
=== LoadAvgCheck Manager Status ===

Health Check Status:
  ✓ fmos.health.checks.basic.LoadAvgCheck is currently ENABLED

Script Location:
  /home/admin/manage_loadavg_check.sh

API Authentication:
  Stored credentials: ✓ (user: adam)

Backup Schedule:
  Enabled: true
  Schedule: daily at 23:48

Cronjob Status:
  43 23 * * * /bin/bash /home/admin/manage_loadavg_check.sh disable >/dev/null 2>&1

Post-backup Configuration:
  ✓ Post-backup script configured

Logging:
  Logging to: /home/admin/loadavg_check_manager.log
  Log size: 4.2K
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

If you see this error, the backup system (running as root) cannot read the script file.

**The Fix:**
```bash
# Ensure the script has proper permissions (755 = rwxr-xr-x)
chmod 755 ~/manage_loadavg_check.sh

# Verify the permissions
ls -la ~/manage_loadavg_check.sh
# Should show: -rwxr-xr-x (or similar with at least r-x for others)

# Also ensure the home directory is accessible
chmod 755 ~

# Test that root can access the file
sudo ls -la ~/manage_loadavg_check.sh
```

After fixing permissions, the next backup should succeed.

**If permission errors persist after chmod 755:**

This could be an SELinux issue. Check and fix SELinux contexts:

```bash
# Check if SELinux is enforcing
getenforce

# Check the SELinux context of the script
ls -Z ~/manage_loadavg_check.sh

# Fix SELinux context to allow root execution
chcon -t bin_t ~/manage_loadavg_check.sh

# OR restore default SELinux context
restorecon -v ~/manage_loadavg_check.sh

# If issues persist, check SELinux audit logs
sudo ausearch -m avc -ts recent | grep manage_loadavg_check

# Temporary workaround (not recommended for production):
# Set SELinux to permissive mode to test
sudo setenforce 0
# Run a backup to see if it succeeds
# Then set it back to enforcing
sudo setenforce 1
```

**Permanent SELinux fix:**

```bash
# Move script to a system location (not home directory)
sudo cp ~/manage_loadavg_check.sh /usr/local/bin/
sudo chmod 755 /usr/local/bin/manage_loadavg_check.sh
sudo chown root:root /usr/local/bin/manage_loadavg_check.sh

# Update the script path and re-run setup
cd /usr/local/bin
sudo bash manage_loadavg_check.sh setup
```

Alternatively, create a proper SELinux policy for the script in the home directory (advanced users).

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
bash /home/admin/manage_loadavg_check.sh credentials

# Re-run setup to update both credentials and post-backup config
bash /home/admin/manage_loadavg_check.sh setup
```

### Permission Denied Error (Direct Execution)

If you encounter "Permission denied" when executing the script directly:

```bash
# FMOS may have noexec on home directory, use bash explicitly
bash ~/manage_loadavg_check.sh setup

# Create an alias for convenience
echo "alias manage_loadavg='bash ~/manage_loadavg_check.sh'" >> ~/.bashrc
source ~/.bashrc
manage_loadavg status
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
  43 23 * * * /bin/bash /home/admin/manage_loadavg_check.sh disable >/dev/null 2>&1

  ⚠ WARNING: Cronjob schedule is out of sync!
  Current cronjob: 23:43
  Should be:       01:55 (5 min before backup at 02:00)
  Run 'bash /home/admin/manage_loadavg_check.sh enable' or 'disable' to auto-update
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
# Manually re-enable the check (waits 15 minutes)
bash ~/manage_loadavg_check.sh enable

# Or re-enable immediately without waiting
bash ~/manage_loadavg_check.sh enable --no-wait

# Verify it's enabled
bash ~/manage_loadavg_check.sh status
```

### Complete Removal

To completely remove all configurations:

```bash
# Remove all setup and re-enable checks
# This removes:
#   - Pre-backup cronjob
#   - Post-backup hook configuration
#   - Stored API credentials
#   - Re-enables LoadAvgCheck
bash ~/manage_loadavg_check.sh cleanup

# Optionally remove the script and logs
rm -f ~/manage_loadavg_check.sh
rm -f ~/loadavg_check_manager.log
rm -f ~/.fmos_api_creds
```

## Security Considerations

- Designed for FMOS virtual appliance (no root/sudo access required)
- Script uses explicit `/bin/bash` interpreter to work when executed by backup system (root)
- **Script permissions**: Script file must be 755 (rwxr-xr-x) to allow root to read/execute during post-backup
- **SELinux considerations**: If SELinux is enforcing, the script may need proper security contexts (see Troubleshooting)
- **API-based authentication**: Uses FMOS Control Panel API instead of CLI commands
- **Credential storage**: Base64 encoded in `.fmos_api_creds` with 644 permissions (readable by all, writable by owner only)
- **Portable design**: Dynamically detects admin username - no hardcoded values
- All operations use FMOS Control Panel API (`https://localhost:55555/api`)
- All operations logged for audit purposes (when logging enabled)
- No direct system file modifications - all changes via API
- Cronjob runs with admin user privileges
- **Simple architecture**: Script runs from wherever placed - no temporary copies needed

## Support

For issues or questions:
1. Check the log file: `cat ~/loadavg_check_manager.log`
2. Verify FMOS backup configuration: `fmos config get os/backup/auto-backup`
3. Check health configuration: `fmos config get os/health`
4. Run status command: `bash ~/manage_loadavg_check.sh status`

## License

This script is provided as-is for use with FMOS systems. Modify as needed for your environment.

## Contributing

Improvements and bug fixes are welcome. Please test thoroughly in a non-production environment before deploying to production FMOS systems.

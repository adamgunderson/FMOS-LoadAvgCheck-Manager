# FMOS LoadAvgCheck Manager

A utility script for FireMon OS (FMOS) that automatically manages the LoadAvgCheck health check during backup operations to prevent false alerts caused by high system load during backups.

## Overview

During FMOS backup operations, system load can spike significantly, triggering the LoadAvgCheck health monitor and generating unnecessary alerts. This script automatically disables the LoadAvgCheck before backups begin and re-enables it after completion, ensuring clean backup operations without false positive health alerts.

## Features

- **Automatic Check Management**: Disables LoadAvgCheck before backups, re-enables after completion
- **Cronjob Integration**: Automatically schedules pre-backup check disable
- **Post-Backup Hooks**: Configures FMOS post-backup scripts for automatic re-enable
- **Noexec Workaround**: Automatically copies script to `/tmp` to bypass `/home` noexec restrictions
- **Flexible Logging**: Optional logging with control over verbosity
- **Status Monitoring**: View current configuration and check status
- **Safe Configuration**: Uses `jq` for safe JSON manipulation without overwriting other settings
- **Sync Command**: Easily update `/tmp` copy after script modifications

## Requirements

- FMOS virtual appliance with admin user access
- `jq` installed (for JSON processing)
- Bash shell (standard on FMOS)
- No root/sudo access required

## Installation

### Download from GitHub

```bash
# Download the script directly to your home directory
wget -O ~/manage_loadavg_check.sh https://raw.githubusercontent.com/adamgunderson/FMOS-LoadAvgCheck-Manager/main/manage_loadavg_check.sh

# Make it executable (note: may need to run with bash due to FMOS security)
chmod +x ~/manage_loadavg_check.sh

# Verify installation
bash ~/manage_loadavg_check.sh status
```

### Manual Installation

If `wget` is not available or you prefer manual installation:

1. Copy the script content to your FMOS system
2. Save it to your home directory as `manage_loadavg_check.sh`
3. Make it executable: `chmod +x ~/manage_loadavg_check.sh`

## Quick Start

```bash
# Run the automatic setup
bash ~/manage_loadavg_check.sh setup

# Verify the configuration
bash ~/manage_loadavg_check.sh status
```

This will:
1. Configure a cronjob to disable LoadAvgCheck 5 minutes before backup
2. Set up post-backup scripts to re-enable the check after backup completion
3. Show the current configuration status

## Usage

### Basic Commands

```bash
# Show help and usage information
bash ~/manage_loadavg_check.sh

# Manually disable the LoadAvgCheck
bash ~/manage_loadavg_check.sh disable

# Manually enable the LoadAvgCheck
bash ~/manage_loadavg_check.sh enable

# Run full automatic setup
bash ~/manage_loadavg_check.sh setup

# Remove all configurations and cleanup
bash ~/manage_loadavg_check.sh cleanup

# Show current status and configuration
bash ~/manage_loadavg_check.sh status

# Sync script to /tmp (after making updates to the script)
bash ~/manage_loadavg_check.sh sync

# Toggle logging on for debugging
bash ~/manage_loadavg_check.sh logging on

# Toggle logging off (return to silent mode)
bash ~/manage_loadavg_check.sh logging off
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

## How It Works

### Backup Schedule Detection

The script automatically detects your FMOS backup schedule:
- Reads configuration from `fmos config get os/backup/auto-backup`
- Uses default time (23:48) if no custom schedule is configured
- Calculates pre-backup time (5 minutes before backup)

### Configuration Flow

1. **Setup Phase**
   - Script copies itself to `/tmp/manage_loadavg_check.sh` (bypasses `/home` noexec restriction)
   - Configures cronjob for pre-backup disable
   - Configures post-backup hook to run from `/tmp`

2. **Pre-Backup (Cronjob)**
   - Runs 5 minutes before scheduled backup
   - Adds `fmos.health.checks.basic.LoadAvgCheck` to ignore list
   - Updates FMOS configuration with `fmos config put` and `fmos config apply`

3. **Post-Backup (Hook)**
   - Triggered automatically by FMOS after backup completion (runs as root)
   - Executes `/tmp/manage_loadavg_check.sh enable` (bypasses `/home` noexec)
   - Removes LoadAvgCheck from ignore list
   - Runs on both backup success and failure

### File Locations

- **Script Source**: `/home/admin/manage_loadavg_check.sh` (or wherever you place it - uses absolute paths)
- **Script Copy**: `/tmp/manage_loadavg_check.sh` (created during setup, used by post-backup hook)
- **Log File**: Located in same directory as source script (e.g., `/home/admin/loadavg_check_manager.log`)
- **Cronjob**: Admin user's crontab
- **FMOS Config**: Modified paths:
  - `os/health` - Health check ignore list
  - `os/backup/post-backup` - Post-backup script hooks (executed by backup system as root)

**Note**: The `/tmp` copy is necessary because `/home` is typically mounted with `noexec` on FMOS appliances. The `/tmp` copy is automatically created/updated during `setup` and can be manually synced with the `sync` command.

## Status Output Example

```
=== LoadAvgCheck Manager Status ===

Health Check Status:
  ✓ fmos.health.checks.basic.LoadAvgCheck is currently ENABLED

Script Locations:
  Source: /home/admin/manage_loadavg_check.sh
  /tmp copy: EXISTS (✓ up to date)

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

### Post-Backup Action Permission Denied (Root Execution)

If you see "Post-backup action failed: [Errno 13] Permission denied" in cron emails:

**Problem**: On FMOS virtual appliances, `/home` is typically mounted with the `noexec` flag, which prevents execution of ANY files from that location - even through bash. The backup system runs as root and cannot execute scripts from `/home`.

**Solution - Use /tmp Copy** (Automatic in updated script):
```bash
# The script now automatically copies itself to /tmp during setup
# /tmp typically does NOT have noexec restrictions
bash /home/admin/manage_loadavg_check.sh setup

# Verify the /tmp copy was created
bash /home/admin/manage_loadavg_check.sh status

# Check the post-backup configuration
fmos config get os/backup/post-backup
# Should show: "command": "/bin/bash /tmp/manage_loadavg_check.sh enable"
```

**After Script Updates**:
```bash
# If you update the script, sync the /tmp copy
bash /home/admin/manage_loadavg_check.sh sync

# Verify it's up to date
bash /home/admin/manage_loadavg_check.sh status
```

**Verify noexec is the issue**:
```bash
# Check if /home has noexec flag
mount | grep /home
# If you see "noexec" in the output, that's the issue

# The /tmp directory should NOT have noexec
mount | grep /tmp
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

### /tmp Copy Missing After Reboot

If backups start failing after a system reboot:

**Problem**: `/tmp` is cleared on reboot, so the script copy is lost.

**Solution**:
```bash
# Simply re-run setup or sync to recreate the /tmp copy
bash /home/admin/manage_loadavg_check.sh setup

# Or use sync if setup was already run
bash /home/admin/manage_loadavg_check.sh sync

# Verify the copy exists
bash /home/admin/manage_loadavg_check.sh status
```

**Automatic Solution** (Optional):
```bash
# Add sync command to admin user's crontab to run at boot
(crontab -l 2>/dev/null; echo "@reboot sleep 60 && /bin/bash /home/admin/manage_loadavg_check.sh sync >/dev/null 2>&1") | crontab -
```

### Verify Check is Being Disabled

```bash
# Check current ignore list
fmos config get os/health | jq '.health.ignore_checks'

# Monitor the log file (if logging enabled)
tail -f ~/loadavg_check_manager.log
```

### Manual Recovery

If automatic re-enable fails:

```bash
# Manually re-enable the check
bash ~/manage_loadavg_check.sh enable

# Verify it's enabled
bash ~/manage_loadavg_check.sh status
```

### Complete Removal

To completely remove all configurations:

```bash
# Remove all setup and re-enable checks
bash ~/manage_loadavg_check.sh cleanup

# Optionally remove the script and logs
rm -f ~/manage_loadavg_check.sh
rm -f ~/loadavg_check_manager.log
```

## Security Considerations

- Designed for FMOS virtual appliance (no root/sudo access required)
- Script uses explicit `/bin/bash` interpreter to work when executed by backup system (root)
- Uses absolute paths to work correctly regardless of which user runs the script
- Uses FMOS native configuration management (`fmos config`)
- All operations logged for audit purposes (when logging enabled)
- No system files are modified directly
- Cronjob runs with admin user privileges
- **Note on /tmp usage**: The script copies itself to `/tmp` to bypass `/home` noexec restrictions. This is necessary for FMOS appliances and is a standard workaround. The `/tmp` copy is cleared on reboot and can be recreated with the `sync` command.

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

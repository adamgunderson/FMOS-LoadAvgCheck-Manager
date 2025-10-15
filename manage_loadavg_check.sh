#!/bin/bash
# Description: Manages LoadAvgCheck health check during FMOS backup operations
# Location: Can be placed anywhere (uses absolute paths, recommended: /home/admin/)

set -e

# Configuration
# Get the absolute path to this script (works regardless of $HOME)
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LOG_FILE="${SCRIPT_DIR}/loadavg_check_manager.log"
CHECK_NAME="fmos.health.checks.basic.LoadAvgCheck"

# Logging control - set to 1 to disable logging, can be overridden by environment variable
NO_LOG="${NO_LOG:-0}"

# Check for --no-log flag
for arg in "$@"; do
    if [ "$arg" = "--no-log" ]; then
        NO_LOG=1
        # Remove --no-log from arguments
        set -- "${@/--no-log/}"
    fi
done

# Logging function
log_message() {
    if [ "$NO_LOG" = "0" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    else
        # Still output to console when running interactively, just don't log to file
        if [ -t 1 ]; then
            echo "$1"
        fi
    fi
}

# Function to disable LoadAvgCheck
disable_check() {
    log_message "Starting: Disabling $CHECK_NAME"
    
    # Get current health config and add the ignore check
    current_config=$(fmos config get os/health 2>/dev/null || echo '{}')
    
    # Use jq to add the check to ignore_checks array (avoiding duplicates)
    updated_config=$(echo "$current_config" | jq --arg check "$CHECK_NAME" '
        .health.ignore_checks = (
            (.health.ignore_checks // []) | 
            if index($check) then . else . + [$check] end
        )
    ')
    
    # Apply the configuration
    echo "$updated_config" | fmos config put os/health - && fmos config apply all
    
    if [ $? -eq 0 ]; then
        log_message "Success: $CHECK_NAME has been disabled"
    else
        log_message "Error: Failed to disable $CHECK_NAME"
        return 1
    fi
}

# Function to enable LoadAvgCheck (remove from ignore list)
enable_check() {
    log_message "Starting: Enabling $CHECK_NAME"
    
    # Get current health config
    current_config=$(fmos config get os/health 2>/dev/null || echo '{}')
    
    # Use jq to remove the check from ignore_checks array
    updated_config=$(echo "$current_config" | jq --arg check "$CHECK_NAME" '
        if .health.ignore_checks then
            .health.ignore_checks = (.health.ignore_checks | map(select(. != $check)))
        else
            .
        end |
        if .health.ignore_checks == [] then
            del(.health.ignore_checks)
        else
            .
        end
    ')
    
    # Apply the configuration
    echo "$updated_config" | fmos config put os/health - && fmos config apply all
    
    if [ $? -eq 0 ]; then
        log_message "Success: $CHECK_NAME has been enabled"
    else
        log_message "Error: Failed to enable $CHECK_NAME"
        return 1
    fi
}

# Function to setup post-backup script execution
setup_post_backup() {
    log_message "Setting up post-backup script execution"

    # Copy script to /tmp to avoid noexec issues on /home
    # /tmp typically allows execution even on locked-down appliances
    local tmp_script="/tmp/manage_loadavg_check.sh"
    cp "$SCRIPT_PATH" "$tmp_script"
    chmod +x "$tmp_script"

    log_message "Script copied to $tmp_script (bypasses /home noexec restrictions)"

    # Use the /tmp copy for post-backup execution
    post_backup_cmd="/bin/bash $tmp_script enable"
    if [ "$NO_LOG" = "1" ]; then
        post_backup_cmd="NO_LOG=1 /bin/bash $tmp_script enable"
    fi

    # Create the post-backup configuration
    post_backup_config=$(cat <<EOF
{
  "post_backup": {
    "failure": {
      "run-command": [
        {
          "command": "$post_backup_cmd"
        }
      ]
    },
    "success": {
      "run-command": [
        {
          "command": "$post_backup_cmd"
        }
      ]
    }
  }
}
EOF
)

    # Apply the post-backup configuration
    echo "$post_backup_config" | fmos config put os/backup/post-backup - && fmos config apply all

    if [ $? -eq 0 ]; then
        log_message "Success: Post-backup script execution configured (using $tmp_script)"
    else
        log_message "Error: Failed to configure post-backup script execution"
        return 1
    fi
}

# Function to setup cronjob for pre-backup disable
setup_cronjob() {
    log_message "Setting up cronjob for pre-backup check disable"
    
    # Get current backup schedule
    backup_config=$(fmos config get os/backup/auto-backup 2>/dev/null || echo '{}')
    
    # Extract backup time (defaults if not set)
    if [ "$backup_config" = "{}" ]; then
        # Use default time
        backup_hour=23
        backup_minute=48
        schedule="daily"
    else
        backup_hour=$(echo "$backup_config" | jq -r '.auto_backup.hour // 23')
        backup_minute=$(echo "$backup_config" | jq -r '.auto_backup.minute // 48')
        schedule=$(echo "$backup_config" | jq -r '.auto_backup.schedule // "daily"')
    fi
    
    # Calculate time 5 minutes before backup
    pre_backup_minute=$((backup_minute - 5))
    pre_backup_hour=$backup_hour
    
    if [ $pre_backup_minute -lt 0 ]; then
        pre_backup_minute=$((60 + pre_backup_minute))
        pre_backup_hour=$((backup_hour - 1))
        if [ $pre_backup_hour -lt 0 ]; then
            pre_backup_hour=23
        fi
    fi
    
    # Create cronjob entry with output redirected to /dev/null
    # Use explicit bash interpreter to avoid permission issues
    # Include NO_LOG environment variable if logging is disabled
    if [ "$NO_LOG" = "1" ]; then
        cron_entry="$pre_backup_minute $pre_backup_hour * * * NO_LOG=1 /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
    else
        cron_entry="$pre_backup_minute $pre_backup_hour * * * /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
    fi
    
    # Add to crontab (avoiding duplicates)
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" || true; echo "$cron_entry") | crontab -
    
    log_message "Cronjob configured: $cron_entry"
    echo "Backup is scheduled at: $backup_hour:$(printf '%02d' $backup_minute)"
    echo "LoadAvgCheck will be disabled at: $pre_backup_hour:$(printf '%02d' $pre_backup_minute)"
}

# Function to remove all setup
cleanup_setup() {
    log_message "Removing all setup configurations"

    # Remove cronjob
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" | crontab - || true
    log_message "Cronjob removed"

    # Clear post-backup configuration
    echo '{"post_backup": {}}' | fmos config put os/backup/post-backup - && fmos config apply all
    log_message "Post-backup configuration cleared"

    # Remove /tmp copy
    rm -f /tmp/manage_loadavg_check.sh 2>/dev/null || true
    log_message "Removed /tmp script copy"

    # Ensure check is enabled
    enable_check
}

# Function to sync script to /tmp
sync_to_tmp() {
    local tmp_script="/tmp/manage_loadavg_check.sh"
    log_message "Syncing script to $tmp_script"

    cp "$SCRIPT_PATH" "$tmp_script"
    chmod +x "$tmp_script"

    if [ $? -eq 0 ]; then
        log_message "Success: Script synced to /tmp"
        echo "Script synced to /tmp (required after any script updates)"
    else
        log_message "Error: Failed to sync script to /tmp"
        return 1
    fi
}

# Function to show current status
show_status() {
    echo "=== LoadAvgCheck Manager Status ==="
    echo

    # Check if LoadAvgCheck is currently ignored
    echo "Health Check Status:"
    current_health=$(fmos config get os/health 2>/dev/null || echo '{}')
    ignored_checks=$(echo "$current_health" | jq -r '.health.ignore_checks[]?' 2>/dev/null)

    if echo "$ignored_checks" | grep -q "$CHECK_NAME"; then
        echo "  ✗ $CHECK_NAME is currently DISABLED"
    else
        echo "  ✓ $CHECK_NAME is currently ENABLED"
    fi
    echo

    # Check /tmp copy status
    echo "Script Locations:"
    echo "  Source: $SCRIPT_PATH"
    if [ -f "/tmp/manage_loadavg_check.sh" ]; then
        tmp_age=$(stat -c %Y "/tmp/manage_loadavg_check.sh" 2>/dev/null || echo "0")
        src_age=$(stat -c %Y "$SCRIPT_PATH" 2>/dev/null || echo "0")
        if [ "$tmp_age" -lt "$src_age" ]; then
            echo "  /tmp copy: EXISTS (⚠ OUTDATED - run 'sync' command)"
        else
            echo "  /tmp copy: EXISTS (✓ up to date)"
        fi
    else
        echo "  /tmp copy: MISSING (⚠ run 'setup' or 'sync' command)"
    fi
    echo
    
    # Show backup schedule
    echo "Backup Schedule:"
    backup_config=$(fmos config get os/backup/auto-backup 2>/dev/null || echo '{}')
    if [ "$backup_config" = "{}" ]; then
        echo "  Using default: Daily at 23:48"
    else
        enabled=$(echo "$backup_config" | jq -r '.auto_backup.enabled // true')
        schedule=$(echo "$backup_config" | jq -r '.auto_backup.schedule // "daily"')
        hour=$(echo "$backup_config" | jq -r '.auto_backup.hour // 23')
        minute=$(echo "$backup_config" | jq -r '.auto_backup.minute // 48')
        echo "  Enabled: $enabled"
        echo "  Schedule: $schedule at $(printf '%02d:%02d' $hour $minute)"
    fi
    echo
    
    # Show cronjob
    echo "Cronjob Status:"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH disable"; then
        crontab -l | grep "$SCRIPT_PATH disable" | while read line; do
            echo "  $line"
        done
    else
        echo "  No cronjob configured"
    fi
    echo
    
    # Show post-backup configuration
    echo "Post-backup Configuration:"
    post_backup=$(fmos config get os/backup/post-backup 2>/dev/null || echo '{}')
    if echo "$post_backup" | jq -e '.post_backup.success."run-command"[]' >/dev/null 2>&1; then
        echo "  ✓ Post-backup script configured"
    else
        echo "  ✗ Post-backup script not configured"
    fi
    echo
    
    # Show logging status
    echo "Logging:"
    if [ "$NO_LOG" = "1" ]; then
        echo "  Logging is DISABLED"
    else
        echo "  Logging to: $LOG_FILE"
        if [ -f "$LOG_FILE" ]; then
            log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
            echo "  Log size: $log_size"
        fi
    fi
}

# Function to toggle logging
toggle_logging() {
    local tmp_script="/tmp/manage_loadavg_check.sh"

    if [ "$1" = "on" ]; then
        echo "Enabling logging..."
        # Update cronjob to add NO_LOG=0 for logging
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH disable"; then
            minute=$(crontab -l | grep "$SCRIPT_PATH disable" | awk '{print $1}')
            hour=$(crontab -l | grep "$SCRIPT_PATH disable" | awk '{print $2}')
            cron_entry="$minute $hour * * * NO_LOG=0 /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
            (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" || true; echo "$cron_entry") | crontab -
        fi
        # Update post-backup (use /tmp copy to avoid noexec)
        # Ensure /tmp copy exists
        cp "$SCRIPT_PATH" "$tmp_script" 2>/dev/null || true
        chmod +x "$tmp_script" 2>/dev/null || true
        post_backup_cmd="NO_LOG=0 /bin/bash $tmp_script enable"
        echo "{\"post_backup\":{\"failure\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]},\"success\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]}}}" | \
            fmos config put os/backup/post-backup - && fmos config apply all
        echo "Logging has been enabled"
    elif [ "$1" = "off" ]; then
        echo "Disabling logging..."
        # Update cronjob to remove NO_LOG (defaults to disabled)
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH disable"; then
            minute=$(crontab -l | grep "$SCRIPT_PATH disable" | awk '{print $1}')
            hour=$(crontab -l | grep "$SCRIPT_PATH disable" | awk '{print $2}')
            cron_entry="$minute $hour * * * /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
            (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" || true; echo "$cron_entry") | crontab -
        fi
        # Update post-backup (use /tmp copy to avoid noexec)
        # Ensure /tmp copy exists
        cp "$SCRIPT_PATH" "$tmp_script" 2>/dev/null || true
        chmod +x "$tmp_script" 2>/dev/null || true
        post_backup_cmd="/bin/bash $tmp_script enable"
        echo "{\"post_backup\":{\"failure\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]},\"success\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]}}}" | \
            fmos config put os/backup/post-backup - && fmos config apply all
        echo "Logging has been disabled (back to default)"
    else
        echo "Usage: $0 logging {on|off}"
        exit 1
    fi
}

# Main script logic
case "${1:-}" in
    disable)
        disable_check
        ;;
    enable)
        enable_check
        ;;
    setup)
        log_message "Running full setup"
        setup_post_backup
        setup_cronjob
        log_message "Setup complete"
        echo
        show_status
        ;;
    cleanup)
        cleanup_setup
        ;;
    status)
        show_status
        ;;
    sync)
        sync_to_tmp
        ;;
    logging)
        toggle_logging "${2:-}"
        ;;
    *)
        echo "FireMon OS LoadAvgCheck Manager"
        echo "================================"
        echo
        echo "Usage: $0 [--no-log] {disable|enable|setup|cleanup|status|sync|logging}"
        echo
        echo "Commands:"
        echo "  disable  - Disable LoadAvgCheck health check"
        echo "  enable   - Enable LoadAvgCheck health check"
        echo "  setup    - Configure cronjob and post-backup execution"
        echo "  cleanup  - Remove all configurations and enable check"
        echo "  status   - Show current configuration status"
        echo "  sync     - Sync script to /tmp (needed after script updates)"
        echo "  logging  - Toggle logging on/off (usage: logging {on|off})"
        echo
        echo "Options:"
        echo "  --no-log - Disable logging for this execution"
        echo
        echo "Setup Instructions:"
        echo "  1. Copy this script to a permanent location (e.g., /home/admin/):"
        echo "     cp $0 /home/admin/manage_loadavg_check.sh"
        echo "  2. Make it executable:"
        echo "     chmod +x /home/admin/manage_loadavg_check.sh"
        echo "  3. Run setup:"
        echo "     /home/admin/manage_loadavg_check.sh setup"
        echo "  4. (Optional) Disable logging:"
        echo "     /home/admin/manage_loadavg_check.sh logging off"
        echo
        echo "Environment Variables:"
        echo "  NO_LOG=1 - Disable logging (alternative to --no-log flag)"
        echo
        echo "The script will:"
        echo "  - Copy itself to /tmp to bypass /home noexec restrictions"
        echo "  - Disable LoadAvgCheck 5 minutes before backup starts (via cron)"
        echo "  - Re-enable LoadAvgCheck after backup completes (via post-backup hook)"
        echo
        echo "Notes:"
        echo "  - /tmp copy is used for post-backup execution (bypasses noexec on /home)"
        echo "  - After updating this script, run 'sync' to update /tmp copy"
        echo "  - /tmp copy is recreated on each 'setup' or 'sync' command"
        echo
        exit 1
        ;;
esac

exit 0

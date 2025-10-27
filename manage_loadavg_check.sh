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

# Detect the admin user dynamically
# When run from /tmp by root, we need to know which user to su to for fmos commands
detect_admin_user() {
    local detected_user=""

    # Method 1: If not running as root, use current user
    if [ "$USER" != "root" ] && [ -n "$USER" ]; then
        detected_user="$USER"
    # Method 2: Try to find the source script in /home and get its owner
    elif [ -f "/home/*/manage_loadavg_check.sh" ] 2>/dev/null; then
        local source_script=$(ls /home/*/manage_loadavg_check.sh 2>/dev/null | head -1)
        if [ -n "$source_script" ]; then
            detected_user=$(stat -c '%U' "$source_script" 2>/dev/null)
        fi
    fi

    # Method 3: Try to extract from script directory path
    if [ -z "$detected_user" ]; then
        detected_user=$(echo "$SCRIPT_DIR" | grep -oP '(?<=/home/)[^/]+' | head -1)
    fi

    # Method 4: Look for first non-root user in /home
    if [ -z "$detected_user" ]; then
        detected_user=$(ls -1 /home 2>/dev/null | head -1)
    fi

    # Fallback: default to "admin"
    if [ -z "$detected_user" ]; then
        detected_user="admin"
    fi

    echo "$detected_user"
}

ADMIN_USER=$(detect_admin_user)

# Logging control - set to 1 to disable logging, can be overridden by environment variable
NO_LOG="${NO_LOG:-0}"

# Wait control - set to 1 to skip the 15 minute wait when re-enabling, can be overridden by environment variable
NO_WAIT="${NO_WAIT:-0}"

# Check for --no-log and --no-wait flags
for arg in "$@"; do
    if [ "$arg" = "--no-log" ]; then
        NO_LOG=1
        # Remove --no-log from arguments
        set -- "${@/--no-log/}"
    fi
    if [ "$arg" = "--no-wait" ]; then
        NO_WAIT=1
        # Remove --no-wait from arguments
        set -- "${@/--no-wait/}"
    fi
done

# API Configuration
API_BASE_URL="https://localhost:55555/api"
API_COOKIE_FILE="/tmp/.fmos_api_cookie_$$"
API_CREDS_FILE="${SCRIPT_DIR}/.fmos_api_creds"

# Function to call FMOS API
# Uses curl with session cookies to interact with the Control Panel API
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local content_type="${4:-application/json}"

    local curl_opts="-k -s -S"  # -k for self-signed cert, -s silent, -S show errors

    if [ -f "$API_COOKIE_FILE" ]; then
        curl_opts="$curl_opts -b $API_COOKIE_FILE"
    fi
    curl_opts="$curl_opts -c $API_COOKIE_FILE"

    if [ -n "$data" ]; then
        curl $curl_opts -X "$method" \
            -H "Content-Type: $content_type" \
            -H "Accept: application/json" \
            -d "$data" \
            "${API_BASE_URL}${endpoint}"
    else
        curl $curl_opts -X "$method" \
            -H "Accept: application/json" \
            "${API_BASE_URL}${endpoint}"
    fi
}

# Function to store API credentials securely
store_credentials() {
    local username="$1"
    local password="$2"

    # Base64 encode for basic obfuscation (not encryption, but better than plain text)
    local encoded_user=$(echo -n "$username" | base64)
    local encoded_pass=$(echo -n "$password" | base64)

    # Write to file with restricted permissions
    cat > "$API_CREDS_FILE" <<EOF
${encoded_user}
${encoded_pass}
EOF

    chmod 644 "$API_CREDS_FILE"
    log_message "Credentials stored securely in $API_CREDS_FILE"
}

# Function to retrieve stored credentials
get_stored_credentials() {
    if [ ! -f "$API_CREDS_FILE" ]; then
        return 1
    fi

    # Read and decode credentials
    local encoded_user=$(sed -n '1p' "$API_CREDS_FILE")
    local encoded_pass=$(sed -n '2p' "$API_CREDS_FILE")

    if [ -n "$encoded_user" ] && [ -n "$encoded_pass" ]; then
        STORED_USER=$(echo "$encoded_user" | base64 -d 2>/dev/null)
        STORED_PASS=$(echo "$encoded_pass" | base64 -d 2>/dev/null)
        return 0
    else
        return 1
    fi
}

# Function to prompt for credentials
prompt_credentials() {
    echo ""
    echo "=== FMOS Control Panel API Credentials ==="
    echo "These credentials will be stored securely and used for API access."
    echo ""

    # Prompt for username with default
    read -p "Username [$ADMIN_USER]: " input_user
    local username="${input_user:-$ADMIN_USER}"

    # Prompt for password (hidden input)
    read -s -p "Password: " password
    echo ""

    # Confirm password
    read -s -p "Confirm password: " password2
    echo ""

    if [ "$password" != "$password2" ]; then
        echo "ERROR: Passwords do not match"
        return 1
    fi

    if [ -z "$password" ]; then
        echo "ERROR: Password cannot be empty"
        return 1
    fi

    # Test credentials before storing
    echo "Testing credentials..."
    local response=$(curl -k -s -S -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Accept: application/json" \
        -d "username=${username}&password=${password}" \
        "${API_BASE_URL}/login" 2>&1)

    if echo "$response" | grep -q '"username"'; then
        echo "✓ Credentials validated successfully"
        store_credentials "$username" "$password"
        return 0
    else
        echo "✗ Login failed - please check your credentials"
        echo "Response: $response"
        return 1
    fi
}

# Function to login to API
# Gets credentials from stored file, environment variables, or prompts user
api_login() {
    local username=""
    local password=""

    # Priority 1: Environment variables
    if [ -n "${FMOS_API_USER:-}" ] && [ -n "${FMOS_API_PASS:-}" ]; then
        username="$FMOS_API_USER"
        password="$FMOS_API_PASS"
        log_message "DEBUG: Using credentials from environment variables"
    # Priority 2: Stored credentials file
    elif get_stored_credentials; then
        username="$STORED_USER"
        password="$STORED_PASS"
        log_message "DEBUG: Using stored credentials for user: $username"
    # Priority 3: Try without authentication (may work from localhost)
    else
        log_message "DEBUG: No credentials found, attempting API call without explicit login"
        return 0
    fi

    # Try to login with credentials
    local response=$(api_call "POST" "/login" "username=${username}&password=${password}" "application/x-www-form-urlencoded" 2>&1)
    if echo "$response" | grep -q '"username"'; then
        log_message "DEBUG: API login successful as $username"
        return 0
    else
        log_message "ERROR: API login failed for user $username"
        return 1
    fi
}

# Function to get config via API
api_config_get() {
    local category="$1"
    # URL encode the category (replace / with %2F)
    local encoded_category=$(echo "$category" | sed 's/\//%2F/g')

    api_call "GET" "/config/values/${encoded_category}"
}

# Function to put config via API
api_config_put() {
    local category="$1"
    local data="$2"
    # URL encode the category (replace / with %2F)
    local encoded_category=$(echo "$category" | sed 's/\//%2F/g')

    api_call "PUT" "/config/values/${encoded_category}" "$data"
}

# Function to apply config via API
api_config_apply() {
    api_call "POST" "/config/apply"
}

# Cleanup API session on exit
trap "rm -f $API_COOKIE_FILE" EXIT

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

    # Check if cronjob schedule needs updating
    check_and_update_cronjob

    # Login to API
    api_login

    # Get current health config and add the ignore check
    current_config=$(api_config_get "os/health")

    # Use jq to add the check to ignore_checks array (avoiding duplicates)
    updated_config=$(echo "$current_config" | jq --arg check "$CHECK_NAME" '
        .health.ignore_checks = (
            (.health.ignore_checks // []) |
            if index($check) then . else . + [$check] end
        )
    ')

    # Apply the configuration
    api_config_put "os/health" "$updated_config" && api_config_apply

    if [ $? -eq 0 ]; then
        log_message "Success: $CHECK_NAME has been disabled"
    else
        log_message "Error: Failed to disable $CHECK_NAME"
        return 1
    fi
}

# Function to enable LoadAvgCheck (remove from ignore list)
enable_check() {
    if [ "$NO_WAIT" = "1" ]; then
        log_message "Starting: Enabling $CHECK_NAME (skipping wait)"
    else
        log_message "Starting: Enabling $CHECK_NAME (with 15 minute delay)"
        # Wait 15 minutes for backup load to settle before re-enabling check
        log_message "Waiting 15 minutes for backup load average to settle..."
        sleep 900  # 15 minutes = 900 seconds
        log_message "Wait complete, proceeding to enable $CHECK_NAME"
    fi

    # Check if cronjob schedule needs updating
    check_and_update_cronjob

    # Login to API
    api_login

    # Get current health config
    current_config=$(api_config_get "os/health")

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
    api_config_put "os/health" "$updated_config" && api_config_apply

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

    # Use the script directly from its current location
    # bash can read scripts even from noexec filesystems
    # Use /usr/bin/env to properly set environment variables for FMOS backup system
    post_backup_cmd="/bin/bash $SCRIPT_PATH enable"
    if [ "$NO_LOG" = "1" ]; then
        post_backup_cmd="/usr/bin/env NO_LOG=1 /bin/bash $SCRIPT_PATH enable"
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
    api_login
    api_config_put "os/backup/post-backup" "$post_backup_config" && api_config_apply

    if [ $? -eq 0 ]; then
        log_message "Success: Post-backup script execution configured"
        log_message "Post-backup command: $post_backup_cmd"
    else
        log_message "Error: Failed to configure post-backup script execution"
        return 1
    fi
}

# Function to get backup schedule and calculate pre-backup time
get_backup_schedule() {
    # Get current backup schedule
    api_login
    local backup_config=$(api_config_get "os/backup/auto-backup")
    [ -z "$backup_config" ] && backup_config="{}"

    # Extract backup time (defaults if not set)
    if [ "$backup_config" = "{}" ]; then
        # Use default time
        BACKUP_HOUR=23
        BACKUP_MINUTE=48
        BACKUP_SCHEDULE="daily"
    else
        BACKUP_HOUR=$(echo "$backup_config" | jq -r '.auto_backup.hour // 23')
        BACKUP_MINUTE=$(echo "$backup_config" | jq -r '.auto_backup.minute // 48')
        BACKUP_SCHEDULE=$(echo "$backup_config" | jq -r '.auto_backup.schedule // "daily"')
    fi

    # Calculate time 5 minutes before backup
    PRE_BACKUP_MINUTE=$((BACKUP_MINUTE - 5))
    PRE_BACKUP_HOUR=$BACKUP_HOUR

    if [ $PRE_BACKUP_MINUTE -lt 0 ]; then
        PRE_BACKUP_MINUTE=$((60 + PRE_BACKUP_MINUTE))
        PRE_BACKUP_HOUR=$((BACKUP_HOUR - 1))
        if [ $PRE_BACKUP_HOUR -lt 0 ]; then
            PRE_BACKUP_HOUR=23
        fi
    fi
}

# Function to check if cronjob needs updating
check_and_update_cronjob() {
    # Get current backup schedule
    get_backup_schedule

    # Check if cronjob exists
    if ! crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH disable"; then
        log_message "INFO: Cronjob not configured, skipping schedule check"
        return 0
    fi

    # Get current cronjob schedule
    local current_cron=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH disable" | head -1)
    local current_minute=$(echo "$current_cron" | awk '{print $1}')
    local current_hour=$(echo "$current_cron" | awk '{print $2}')

    # Check if schedule has changed
    if [ "$current_minute" != "$PRE_BACKUP_MINUTE" ] || [ "$current_hour" != "$PRE_BACKUP_HOUR" ]; then
        log_message "INFO: Backup schedule changed, updating cronjob"
        log_message "Old schedule: $current_hour:$(printf '%02d' $current_minute)"
        log_message "New schedule: $PRE_BACKUP_HOUR:$(printf '%02d' $PRE_BACKUP_MINUTE)"

        # Create new cronjob entry
        local cron_entry
        if echo "$current_cron" | grep -q "NO_LOG=1"; then
            cron_entry="$PRE_BACKUP_MINUTE $PRE_BACKUP_HOUR * * * NO_LOG=1 /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
        else
            cron_entry="$PRE_BACKUP_MINUTE $PRE_BACKUP_HOUR * * * /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
        fi

        # Update crontab
        (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" || true; echo "$cron_entry") | crontab -
        log_message "Cronjob updated: $cron_entry"

        echo "⚠ Backup schedule has changed!"
        echo "  Backup is now at: $BACKUP_HOUR:$(printf '%02d' $BACKUP_MINUTE)"
        echo "  Cronjob updated to: $PRE_BACKUP_HOUR:$(printf '%02d' $PRE_BACKUP_MINUTE)"
    fi
}

# Function to setup cronjob for pre-backup disable
setup_cronjob() {
    log_message "Setting up cronjob for pre-backup check disable"

    # Get backup schedule
    get_backup_schedule

    # Create cronjob entry with output redirected to /dev/null
    # Use explicit bash interpreter to avoid permission issues
    # Include NO_LOG environment variable if logging is disabled
    if [ "$NO_LOG" = "1" ]; then
        cron_entry="$PRE_BACKUP_MINUTE $PRE_BACKUP_HOUR * * * NO_LOG=1 /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
    else
        cron_entry="$PRE_BACKUP_MINUTE $PRE_BACKUP_HOUR * * * /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
    fi

    # Add to crontab (avoiding duplicates)
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" || true; echo "$cron_entry") | crontab -

    log_message "Cronjob configured: $cron_entry"
    echo "Backup is scheduled at: $BACKUP_HOUR:$(printf '%02d' $BACKUP_MINUTE)"
    echo "LoadAvgCheck will be disabled at: $PRE_BACKUP_HOUR:$(printf '%02d' $PRE_BACKUP_MINUTE)"
}

# Function to remove all setup
cleanup_setup() {
    log_message "Removing all setup configurations"

    # Remove cronjob
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" | crontab - || true
    log_message "Cronjob removed"

    # Clear post-backup configuration
    api_login
    api_config_put "os/backup/post-backup" '{"post_backup": {}}' && api_config_apply
    log_message "Post-backup configuration cleared"

    # Remove stored credentials
    if [ -f "$API_CREDS_FILE" ]; then
        rm -f "$API_CREDS_FILE"
        log_message "Removed stored API credentials"
    fi

    # Ensure check is enabled
    enable_check
}

# Function to show current status
show_status() {
    echo "=== LoadAvgCheck Manager Status ==="
    echo

    # Check if LoadAvgCheck is currently ignored
    echo "Health Check Status:"
    api_login
    current_health=$(api_config_get "os/health")
    [ -z "$current_health" ] && current_health="{}"
    ignored_checks=$(echo "$current_health" | jq -r '.health.ignore_checks[]?' 2>/dev/null)

    if echo "$ignored_checks" | grep -q "$CHECK_NAME"; then
        echo "  ✗ $CHECK_NAME is currently DISABLED"
    else
        echo "  ✓ $CHECK_NAME is currently ENABLED"
    fi
    echo

    # Show script location
    echo "Script Location:"
    echo "  $SCRIPT_PATH"
    echo

    # Show API authentication status
    echo "API Authentication:"
    if [ -f "$API_CREDS_FILE" ]; then
        get_stored_credentials
        echo "  Stored credentials: ✓ (user: $STORED_USER)"
    elif [ -n "${FMOS_API_USER:-}" ] && [ -n "${FMOS_API_PASS:-}" ]; then
        echo "  Environment variables: ✓ (user: $FMOS_API_USER)"
    else
        echo "  No credentials configured"
    fi
    echo
    
    # Show backup schedule
    echo "Backup Schedule:"
    backup_config=$(api_config_get "os/backup/auto-backup")
    [ -z "$backup_config" ] && backup_config="{}"

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
    
    # Show cronjob with schedule validation
    echo "Cronjob Status:"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH disable"; then
        # Get current backup schedule
        get_backup_schedule 2>/dev/null || true

        # Get current cronjob schedule
        local current_cron=$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH disable" | head -1)
        local current_minute=$(echo "$current_cron" | awk '{print $1}')
        local current_hour=$(echo "$current_cron" | awk '{print $2}')

        # Display cronjob
        echo "  $current_cron"

        # Check if schedule matches current backup time
        if [ -n "$PRE_BACKUP_MINUTE" ] && [ -n "$PRE_BACKUP_HOUR" ]; then
            if [ "$current_minute" != "$PRE_BACKUP_MINUTE" ] || [ "$current_hour" != "$PRE_BACKUP_HOUR" ]; then
                echo ""
                echo "  ⚠ WARNING: Cronjob schedule is out of sync!"
                echo "  Current cronjob: $current_hour:$(printf '%02d' $current_minute)"
                echo "  Should be:       $PRE_BACKUP_HOUR:$(printf '%02d' $PRE_BACKUP_MINUTE) (5 min before backup at $BACKUP_HOUR:$(printf '%02d' $BACKUP_MINUTE))"
                echo "  Run 'bash $SCRIPT_PATH enable' or 'disable' to auto-update"
            fi
        fi
    else
        echo "  No cronjob configured"
    fi
    echo
    
    # Show post-backup configuration
    echo "Post-backup Configuration:"
    post_backup=$(api_config_get "os/backup/post-backup")
    [ -z "$post_backup" ] && post_backup="{}"

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
    if [ "$1" = "on" ]; then
        echo "Enabling logging..."
        # Update cronjob to add NO_LOG=0 for logging
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH disable"; then
            minute=$(crontab -l | grep "$SCRIPT_PATH disable" | awk '{print $1}')
            hour=$(crontab -l | grep "$SCRIPT_PATH disable" | awk '{print $2}')
            cron_entry="$minute $hour * * * NO_LOG=0 /bin/bash $SCRIPT_PATH disable >/dev/null 2>&1"
            (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH disable" || true; echo "$cron_entry") | crontab -
        fi
        # Update post-backup
        post_backup_cmd="/usr/bin/env NO_LOG=0 /bin/bash $SCRIPT_PATH enable"
        post_backup_json="{\"post_backup\":{\"failure\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]},\"success\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]}}}"
        api_login
        api_config_put "os/backup/post-backup" "$post_backup_json" && api_config_apply
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
        # Update post-backup
        post_backup_cmd="/bin/bash $SCRIPT_PATH enable"
        post_backup_json="{\"post_backup\":{\"failure\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]},\"success\":{\"run-command\":[{\"command\":\"$post_backup_cmd\"}]}}}"
        api_login
        api_config_put "os/backup/post-backup" "$post_backup_json" && api_config_apply
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

        # Check if credentials exist, if not prompt for them
        if [ ! -f "$API_CREDS_FILE" ]; then
            echo "API credentials not found. Please provide them now."
            if ! prompt_credentials; then
                echo "Setup aborted: credentials required"
                exit 1
            fi
        else
            echo "Using existing API credentials from $API_CREDS_FILE"
            echo "(To update credentials, run: $0 credentials)"
        fi

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
    credentials)
        echo "Update API credentials"
        if prompt_credentials; then
            echo "Credentials updated successfully"
        else
            echo "Failed to update credentials"
            exit 1
        fi
        ;;
    logging)
        toggle_logging "${2:-}"
        ;;
    *)
        echo "FireMon OS LoadAvgCheck Manager"
        echo "================================"
        echo
        echo "Usage: $0 [--no-log] [--no-wait] {disable|enable|setup|cleanup|status|credentials|logging}"
        echo
        echo "Commands:"
        echo "  disable      - Disable LoadAvgCheck health check"
        echo "  enable       - Enable LoadAvgCheck health check (waits 15 minutes by default)"
        echo "  setup        - Configure cronjob and post-backup execution (prompts for credentials)"
        echo "  cleanup      - Remove all configurations and enable check"
        echo "  status       - Show current configuration status"
        echo "  credentials  - Update stored API credentials"
        echo "  logging      - Toggle logging on/off (usage: logging {on|off})"
        echo
        echo "Options:"
        echo "  --no-log  - Disable logging for this execution"
        echo "  --no-wait - Skip the 15 minute wait when enabling (use with 'enable' command)"
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
        echo "  NO_LOG=1  - Disable logging (alternative to --no-log flag)"
        echo "  NO_WAIT=1 - Skip 15 minute wait when enabling (alternative to --no-wait flag)"
        echo
        echo "The script will:"
        echo "  - Prompt for API credentials (if not already stored)"
        echo "  - Configure cronjob to disable LoadAvgCheck 5 minutes before backup"
        echo "  - Configure post-backup hook to re-enable LoadAvgCheck after backup"
        echo
        echo "Notes:"
        echo "  - Uses FMOS Control Panel API (no CLI permission issues)"
        echo "  - Credentials stored securely in: $API_CREDS_FILE"
        echo "  - Post-backup hook: /bin/bash $SCRIPT_PATH enable"
        echo "  - Updates to this script take effect immediately (no sync needed)"
        echo
        exit 1
        ;;
esac

exit 0

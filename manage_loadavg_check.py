#!/usr/bin/env python3
"""
FireMon OS LoadAvgCheck Manager
Manages LoadAvgCheck health check during FMOS backup operations
"""

import sys
import os
import json
import base64
import time
import argparse
import subprocess
from datetime import datetime
from pathlib import Path
from getpass import getpass
import urllib3

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

try:
    import requests
except ImportError:
    print("ERROR: Python 'requests' module is required")
    print("Install it with: pip3 install requests")
    sys.exit(1)


class FMOSLoadAvgCheckManager:
    """Manages LoadAvgCheck health check during FMOS backup operations"""

    def __init__(self, script_path, no_log=False, no_wait=False):
        self.script_path = Path(script_path).resolve()
        self.script_dir = self.script_path.parent
        self.log_file = self.script_dir / "loadavg_check_manager.log"
        self.creds_file = self.script_dir / ".fmos_api_creds"
        self.check_name = "fmos.health.checks.basic.LoadAvgCheck"
        self.api_base_url = "https://localhost:55555/api"
        self.no_log = no_log or os.environ.get('NO_LOG', '0') == '1'
        self.no_wait = no_wait or os.environ.get('NO_WAIT', '0') == '1'
        self.admin_user = self._detect_admin_user()
        self.session = requests.Session()
        self.session.verify = False  # Self-signed cert

    def _detect_admin_user(self):
        """Detect the admin username dynamically"""
        # Method 1: Current user if not root
        current_user = os.environ.get('USER')
        if current_user and current_user != 'root':
            return current_user

        # Method 2: Extract from script directory path
        try:
            home_match = str(self.script_dir).split('/home/')
            if len(home_match) > 1:
                user = home_match[1].split('/')[0]
                if user:
                    return user
        except:
            pass

        # Method 3: Look for first non-root user in /home
        try:
            home_dir = Path('/home')
            if home_dir.exists():
                users = [d.name for d in home_dir.iterdir() if d.is_dir()]
                if users:
                    return users[0]
        except:
            pass

        # Fallback
        return 'admin'

    def log_message(self, message):
        """Log a message to file and/or console"""
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        log_line = f"[{timestamp}] {message}"

        if not self.no_log:
            try:
                with open(self.log_file, 'a') as f:
                    f.write(log_line + '\n')
            except Exception as e:
                print(f"WARNING: Could not write to log file: {e}")

        # Always output to console if interactive
        if sys.stdout.isatty() or not self.no_log:
            print(message)

    def store_credentials(self, username, password):
        """Store API credentials securely"""
        encoded_user = base64.b64encode(username.encode()).decode()
        encoded_pass = base64.b64encode(password.encode()).decode()

        try:
            with open(self.creds_file, 'w') as f:
                f.write(f"{encoded_user}\n{encoded_pass}\n")
            os.chmod(self.creds_file, 0o644)
            self.log_message(f"Credentials stored securely in {self.creds_file}")
            return True
        except Exception as e:
            self.log_message(f"ERROR: Failed to store credentials: {e}")
            return False

    def get_stored_credentials(self):
        """Retrieve stored credentials"""
        if not self.creds_file.exists():
            return None, None

        try:
            with open(self.creds_file, 'r') as f:
                lines = f.readlines()
                if len(lines) >= 2:
                    username = base64.b64decode(lines[0].strip()).decode()
                    password = base64.b64decode(lines[1].strip()).decode()
                    return username, password
        except Exception as e:
            self.log_message(f"ERROR: Failed to read credentials: {e}")

        return None, None

    def prompt_credentials(self):
        """Prompt user for credentials and validate them"""
        print()
        print("=== FMOS Control Panel API Credentials ===")
        print("These credentials will be stored securely and used for API access.")
        print()

        username = input(f"Username [{self.admin_user}]: ").strip() or self.admin_user

        password = getpass("Password: ")
        password2 = getpass("Confirm password: ")

        if password != password2:
            print("ERROR: Passwords do not match")
            return False

        if not password:
            print("ERROR: Password cannot be empty")
            return False

        # Test credentials
        print("Testing credentials...")
        if self.test_login(username, password):
            print("✓ Credentials validated successfully")
            return self.store_credentials(username, password)
        else:
            print("✗ Login failed - please check your credentials")
            return False

    def test_login(self, username, password):
        """Test API login credentials"""
        try:
            response = self.session.post(
                f"{self.api_base_url}/login",
                data=f"username={username}&password={password}",
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json"
                },
                timeout=10
            )
            return response.ok and "username" in response.text
        except Exception as e:
            self.log_message(f"ERROR: Login test failed: {e}")
            return False

    def api_login(self):
        """Login to the API using stored or environment credentials"""
        # Priority 1: Environment variables
        username = os.environ.get('FMOS_API_USER')
        password = os.environ.get('FMOS_API_PASS')

        if username and password:
            self.log_message("DEBUG: Using credentials from environment variables")
        else:
            # Priority 2: Stored credentials file
            username, password = self.get_stored_credentials()
            if username and password:
                self.log_message(f"DEBUG: Using stored credentials for user: {username}")
            else:
                self.log_message("DEBUG: No credentials found, attempting API call without explicit login")
                return True

        # Try to login
        try:
            response = self.session.post(
                f"{self.api_base_url}/login",
                data=f"username={username}&password={password}",
                headers={
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json"
                },
                timeout=10
            )

            if response.ok and "username" in response.text:
                self.log_message(f"DEBUG: API login successful as {username}")
                return True
            else:
                self.log_message(f"ERROR: API login failed for user {username}")
                return False
        except Exception as e:
            self.log_message(f"ERROR: API login exception: {e}")
            return False

    def api_config_get(self, category):
        """Get configuration via API"""
        try:
            encoded_category = category.replace('/', '%2F')
            response = self.session.get(
                f"{self.api_base_url}/config/values/{encoded_category}",
                headers={"Accept": "application/json"},
                timeout=10
            )

            if response.ok:
                return response.json()
            else:
                self.log_message(f"ERROR: API GET failed: {response.status_code}")
                return {}
        except Exception as e:
            self.log_message(f"ERROR: API GET exception: {e}")
            return {}

    def api_config_put(self, category, data):
        """Put configuration via API"""
        try:
            encoded_category = category.replace('/', '%2F')
            response = self.session.put(
                f"{self.api_base_url}/config/values/{encoded_category}",
                json=data,
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json"
                },
                timeout=10
            )
            return response.ok
        except Exception as e:
            self.log_message(f"ERROR: API PUT exception: {e}")
            return False

    def api_config_apply(self):
        """Apply configuration via API"""
        try:
            response = self.session.post(
                f"{self.api_base_url}/config/apply",
                headers={"Accept": "application/json"},
                timeout=30
            )
            return response.ok
        except Exception as e:
            self.log_message(f"ERROR: API config apply exception: {e}")
            return False

    def get_backup_schedule(self):
        """Get backup schedule and calculate pre-backup time"""
        backup_config = self.api_config_get("os/backup/auto-backup")

        if not backup_config or backup_config == {}:
            # Use defaults
            return {
                'hour': 23,
                'minute': 48,
                'pre_hour': 23,
                'pre_minute': 43,
                'schedule': 'daily'
            }

        hour = backup_config.get('auto_backup', {}).get('hour', 23)
        minute = backup_config.get('auto_backup', {}).get('minute', 48)
        schedule = backup_config.get('auto_backup', {}).get('schedule', 'daily')

        # Calculate 5 minutes before
        pre_minute = minute - 5
        pre_hour = hour

        if pre_minute < 0:
            pre_minute = 60 + pre_minute
            pre_hour = hour - 1
            if pre_hour < 0:
                pre_hour = 23

        return {
            'hour': hour,
            'minute': minute,
            'pre_hour': pre_hour,
            'pre_minute': pre_minute,
            'schedule': schedule
        }

    def disable_check(self):
        """Disable LoadAvgCheck health check"""
        self.log_message(f"Starting: Disabling {self.check_name}")

        # Check and update cronjob if needed
        self.check_and_update_cronjob()

        # Login to API
        if not self.api_login():
            self.log_message("ERROR: API login failed")
            return False

        # Get current health config
        current_config = self.api_config_get("os/health")
        if not current_config:
            current_config = {"health": {}}

        # Add check to ignore list
        ignore_checks = current_config.get('health', {}).get('ignore_checks', [])
        if self.check_name not in ignore_checks:
            ignore_checks.append(self.check_name)

        current_config.setdefault('health', {})['ignore_checks'] = ignore_checks

        # Apply configuration
        if self.api_config_put("os/health", current_config) and self.api_config_apply():
            self.log_message(f"Success: {self.check_name} has been disabled")
            return True
        else:
            self.log_message(f"Error: Failed to disable {self.check_name}")
            return False

    def enable_check(self):
        """Enable LoadAvgCheck health check"""
        if self.no_wait:
            self.log_message(f"Starting: Enabling {self.check_name} (skipping wait)")
        else:
            self.log_message(f"Starting: Enabling {self.check_name} (with 15 minute delay)")
            self.log_message("Waiting 15 minutes for backup load average to settle...")
            time.sleep(900)  # 15 minutes
            self.log_message(f"Wait complete, proceeding to enable {self.check_name}")

        # Check and update cronjob if needed
        self.check_and_update_cronjob()

        # Login to API
        if not self.api_login():
            self.log_message("ERROR: API login failed")
            return False

        # Get current health config
        current_config = self.api_config_get("os/health")
        if not current_config:
            current_config = {"health": {}}

        # Remove check from ignore list
        ignore_checks = current_config.get('health', {}).get('ignore_checks', [])
        if self.check_name in ignore_checks:
            ignore_checks.remove(self.check_name)

        if ignore_checks:
            current_config.setdefault('health', {})['ignore_checks'] = ignore_checks
        else:
            # Remove empty ignore_checks array
            current_config.setdefault('health', {}).pop('ignore_checks', None)

        # Apply configuration
        if self.api_config_put("os/health", current_config) and self.api_config_apply():
            self.log_message(f"Success: {self.check_name} has been enabled")
            return True
        else:
            self.log_message(f"Error: Failed to enable {self.check_name}")
            return False

    def get_current_cron_entry(self):
        """Get current cron entry for this script"""
        try:
            result = subprocess.run(
                ['crontab', '-l'],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if str(self.script_path) in line and 'disable' in line:
                        return line.strip()
        except:
            pass

        return None

    def check_and_update_cronjob(self):
        """Check if cronjob needs updating based on backup schedule"""
        schedule = self.get_backup_schedule()
        current_cron = self.get_current_cron_entry()

        if not current_cron:
            self.log_message("INFO: Cronjob not configured, skipping schedule check")
            return

        # Parse current cron timing
        parts = current_cron.split()
        if len(parts) >= 5:
            current_minute = int(parts[0])
            current_hour = int(parts[1])

            if current_minute != schedule['pre_minute'] or current_hour != schedule['pre_hour']:
                self.log_message("INFO: Backup schedule changed, updating cronjob")
                self.log_message(f"Old schedule: {current_hour}:{current_minute:02d}")
                self.log_message(f"New schedule: {schedule['pre_hour']}:{schedule['pre_minute']:02d}")
                self.setup_cronjob()

    def setup_cronjob(self):
        """Setup cronjob for pre-backup disable"""
        self.log_message("Setting up cronjob for pre-backup check disable")

        schedule = self.get_backup_schedule()

        # Create cron entry
        if self.no_log:
            cron_entry = f"{schedule['pre_minute']} {schedule['pre_hour']} * * * NO_LOG=1 {sys.executable} {self.script_path} disable >/dev/null 2>&1"
        else:
            cron_entry = f"{schedule['pre_minute']} {schedule['pre_hour']} * * * {sys.executable} {self.script_path} disable >/dev/null 2>&1"

        try:
            # Get existing crontab
            result = subprocess.run(
                ['crontab', '-l'],
                capture_output=True,
                text=True,
                timeout=5
            )

            existing_cron = result.stdout if result.returncode == 0 else ""

            # Filter out old entries for this script
            new_cron_lines = [
                line for line in existing_cron.splitlines()
                if str(self.script_path) not in line or 'disable' not in line
            ]

            # Add new entry
            new_cron_lines.append(cron_entry)

            # Write back to crontab
            subprocess.run(
                ['crontab', '-'],
                input='\n'.join(new_cron_lines) + '\n',
                text=True,
                timeout=5
            )

            self.log_message(f"Cronjob configured: {cron_entry}")
            print(f"Backup is scheduled at: {schedule['hour']}:{schedule['minute']:02d}")
            print(f"LoadAvgCheck will be disabled at: {schedule['pre_hour']}:{schedule['pre_minute']:02d}")
            return True
        except Exception as e:
            self.log_message(f"ERROR: Failed to setup cronjob: {e}")
            return False

    def setup_post_backup(self):
        """Setup post-backup script execution"""
        self.log_message("Setting up post-backup script execution")

        # Create command - Python doesn't need /usr/bin/env for variables
        if self.no_log:
            post_backup_cmd = f"NO_LOG=1 {sys.executable} {self.script_path} enable"
        else:
            post_backup_cmd = f"{sys.executable} {self.script_path} enable"

        # Create post-backup configuration
        post_backup_config = {
            "post_backup": {
                "failure": {
                    "run-command": [
                        {"command": post_backup_cmd}
                    ]
                },
                "success": {
                    "run-command": [
                        {"command": post_backup_cmd}
                    ]
                }
            }
        }

        # Apply configuration
        if not self.api_login():
            return False

        if self.api_config_put("os/backup/post-backup", post_backup_config) and self.api_config_apply():
            self.log_message("Success: Post-backup script execution configured")
            self.log_message(f"Post-backup command: {post_backup_cmd}")
            return True
        else:
            self.log_message("Error: Failed to configure post-backup script execution")
            return False

    def setup(self):
        """Full setup process"""
        self.log_message("Running full setup")

        # Check credentials
        if not self.creds_file.exists():
            print("API credentials not found. Please provide them now.")
            if not self.prompt_credentials():
                print("Setup aborted: credentials required")
                return False
        else:
            print(f"Using existing API credentials from {self.creds_file}")
            print(f"(To update credentials, run: {sys.argv[0]} credentials)")

        # Setup components
        if not self.setup_post_backup():
            return False

        if not self.setup_cronjob():
            return False

        self.log_message("Setup complete")
        print()
        self.show_status()
        return True

    def cleanup(self):
        """Remove all setup configurations"""
        self.log_message("Removing all setup configurations")

        # Remove cronjob
        try:
            result = subprocess.run(
                ['crontab', '-l'],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0:
                new_cron_lines = [
                    line for line in result.stdout.splitlines()
                    if str(self.script_path) not in line or 'disable' not in line
                ]

                subprocess.run(
                    ['crontab', '-'],
                    input='\n'.join(new_cron_lines) + '\n',
                    text=True,
                    timeout=5
                )

            self.log_message("Cronjob removed")
        except Exception as e:
            self.log_message(f"WARNING: Failed to remove cronjob: {e}")

        # Clear post-backup configuration
        if self.api_login():
            self.api_config_put("os/backup/post-backup", {"post_backup": {}})
            self.api_config_apply()
            self.log_message("Post-backup configuration cleared")

        # Remove stored credentials
        if self.creds_file.exists():
            self.creds_file.unlink()
            self.log_message("Removed stored API credentials")

        # Ensure check is enabled
        self.no_wait = True  # Skip wait when cleaning up
        self.enable_check()

    def show_status(self):
        """Show current status and configuration"""
        print("=== LoadAvgCheck Manager Status ===")
        print()

        # Health check status
        print("Health Check Status:")
        if self.api_login():
            current_health = self.api_config_get("os/health")
            ignored_checks = current_health.get('health', {}).get('ignore_checks', [])

            if self.check_name in ignored_checks:
                print(f"  ✗ {self.check_name} is currently DISABLED")
            else:
                print(f"  ✓ {self.check_name} is currently ENABLED")
        print()

        # Script location
        print("Script Location:")
        print(f"  {self.script_path}")
        print()

        # API authentication status
        print("API Authentication:")
        if self.creds_file.exists():
            username, _ = self.get_stored_credentials()
            print(f"  Stored credentials: ✓ (user: {username})")
        elif os.environ.get('FMOS_API_USER') and os.environ.get('FMOS_API_PASS'):
            print(f"  Environment variables: ✓ (user: {os.environ['FMOS_API_USER']})")
        else:
            print("  No credentials configured")
        print()

        # Backup schedule
        print("Backup Schedule:")
        schedule = self.get_backup_schedule()
        print(f"  Schedule: {schedule['schedule']} at {schedule['hour']:02d}:{schedule['minute']:02d}")
        print()

        # Cronjob status
        print("Cronjob Status:")
        current_cron = self.get_current_cron_entry()
        if current_cron:
            print(f"  {current_cron}")

            # Check if in sync
            parts = current_cron.split()
            if len(parts) >= 5:
                current_minute = int(parts[0])
                current_hour = int(parts[1])

                if current_minute != schedule['pre_minute'] or current_hour != schedule['pre_hour']:
                    print()
                    print("  ⚠ WARNING: Cronjob schedule is out of sync!")
                    print(f"  Current cronjob: {current_hour}:{current_minute:02d}")
                    print(f"  Should be:       {schedule['pre_hour']}:{schedule['pre_minute']:02d} (5 min before backup at {schedule['hour']}:{schedule['minute']:02d})")
                    print(f"  Run '{sys.argv[0]} enable' or 'disable' to auto-update")
        else:
            print("  No cronjob configured")
        print()

        # Post-backup configuration
        print("Post-backup Configuration:")
        post_backup = self.api_config_get("os/backup/post-backup")
        if post_backup.get('post_backup', {}).get('success', {}).get('run-command'):
            print("  ✓ Post-backup script configured")
        else:
            print("  ✗ Post-backup script not configured")
        print()

        # Logging status
        print("Logging:")
        if self.no_log:
            print("  Logging is DISABLED")
        else:
            print(f"  Logging to: {self.log_file}")
            if self.log_file.exists():
                size = self.log_file.stat().st_size
                size_str = f"{size / 1024:.1f}K" if size < 1024 * 1024 else f"{size / (1024 * 1024):.1f}M"
                print(f"  Log size: {size_str}")


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description='FireMon OS LoadAvgCheck Manager',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Commands:
  disable      - Disable LoadAvgCheck health check
  enable       - Enable LoadAvgCheck health check (waits 15 minutes by default)
  setup        - Configure cronjob and post-backup execution (prompts for credentials)
  cleanup      - Remove all configurations and enable check
  status       - Show current configuration status
  credentials  - Update stored API credentials

Options:
  --no-log     - Disable logging for this execution
  --no-wait    - Skip the 15 minute wait when enabling (use with 'enable' command)

Environment Variables:
  NO_LOG=1     - Disable logging (alternative to --no-log flag)
  NO_WAIT=1    - Skip 15 minute wait when enabling (alternative to --no-wait flag)
  FMOS_API_USER - API username (takes priority over stored credentials)
  FMOS_API_PASS - API password (takes priority over stored credentials)

Examples:
  python3 manage_loadavg_check.py setup
  python3 manage_loadavg_check.py enable --no-wait
  python3 manage_loadavg_check.py status
        """
    )

    parser.add_argument('command',
                       choices=['disable', 'enable', 'setup', 'cleanup', 'status', 'credentials'],
                       help='Command to execute')
    parser.add_argument('--no-log', action='store_true',
                       help='Disable logging for this execution')
    parser.add_argument('--no-wait', action='store_true',
                       help='Skip 15 minute wait when enabling')

    args = parser.parse_args()

    # Get script path
    script_path = Path(__file__).resolve()

    # Create manager instance
    manager = FMOSLoadAvgCheckManager(script_path, args.no_log, args.no_wait)

    # Execute command
    try:
        if args.command == 'disable':
            success = manager.disable_check()
        elif args.command == 'enable':
            success = manager.enable_check()
        elif args.command == 'setup':
            success = manager.setup()
        elif args.command == 'cleanup':
            manager.cleanup()
            success = True
        elif args.command == 'status':
            manager.show_status()
            success = True
        elif args.command == 'credentials':
            success = manager.prompt_credentials()
        else:
            parser.print_help()
            sys.exit(1)

        sys.exit(0 if success else 1)

    except KeyboardInterrupt:
        print("\nInterrupted by user")
        sys.exit(130)
    except Exception as e:
        manager.log_message(f"FATAL ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""
S3 Lifecycle Configuration Manager

This script manages S3 bucket lifecycle configurations with intelligent merging capabilities.
It can merge local configurations with existing remote configurations, preserving existing
rules while allowing local overrides.

Usage:
    python3 s3_lifecycle_manager.py apply <bucket_name> <config_file> [options]
    python3 s3_lifecycle_manager.py test [options]

Dependencies:
    pip install boto3

Version: 3.0 (Python with boto3)
"""

import json
import os
import sys
import argparse
import logging
from datetime import datetime
from typing import Dict, List, Any, Optional
from pathlib import Path

try:
    import boto3
    from botocore.exceptions import ClientError, NoCredentialsError
except ImportError:
    print("Error: boto3 is required. Please install it with: pip install boto3")
    sys.exit(1)


class Colors:
    """ANSI color codes for terminal output."""
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    RESET = '\033[0m'
    BOLD = '\033[1m'

    @staticmethod
    def red(text: str) -> str:
        """Return text in red color."""
        return f"{Colors.RED}{text}{Colors.RESET}"

    @staticmethod
    def green(text: str) -> str:
        """Return text in green color."""
        return f"{Colors.GREEN}{text}{Colors.RESET}"

    @staticmethod
    def yellow(text: str) -> str:
        """Return text in yellow color."""
        return f"{Colors.YELLOW}{text}{Colors.RESET}"


class S3LifecycleManager:
    """Manages S3 bucket lifecycle configurations with intelligent merging."""

    def __init__(self, debug: bool = False, skip_aws_config: bool = False):
        """Initialize the lifecycle manager.

        Args:
            debug: Enable debug logging
            skip_aws_config: Skip AWS configuration setup (for testing)
        """
        self.debug = debug
        self.logger = self._setup_logging()
        self.s3_client = None

        if not skip_aws_config:
            self._setup_aws_client()

    def _setup_logging(self) -> logging.Logger:
        """Setup logging configuration."""
        logger = logging.getLogger('s3_lifecycle_manager')
        logger.setLevel(logging.DEBUG if self.debug else logging.INFO)

        # Clear existing handlers
        logger.handlers.clear()

        handler = logging.StreamHandler()
        formatter = logging.Formatter(
            '%(asctime)s - %(levelname)s - %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        handler.setFormatter(formatter)
        logger.addHandler(handler)

        return logger

    def _setup_aws_client(self) -> None:
        """Setup boto3 S3 client based on environment variables."""
        # Get AWS configuration from environment
        aws_access_key_id = os.getenv('AWS_ACCESS_KEY_ID')
        aws_secret_access_key = os.getenv('AWS_SECRET_ACCESS_KEY')
        aws_region = os.getenv('AWS_DEFAULT_REGION') or None
        s3_endpoint = os.getenv('S3_ENDPOINT')

        # Check required credentials and endpoint
        if not aws_access_key_id or not aws_secret_access_key or not s3_endpoint:
            missing = []
            if not aws_access_key_id:
                missing.append('AWS_ACCESS_KEY_ID')
            if not aws_secret_access_key:
                missing.append('AWS_SECRET_ACCESS_KEY')
            if not s3_endpoint:
                missing.append('S3_ENDPOINT')
            self.logger.error(f"Missing required environment variables: {', '.join(missing)}")
            sys.exit(1)

        # Setup client configuration
        client_config = {
            'aws_access_key_id': aws_access_key_id,
            'aws_secret_access_key': aws_secret_access_key,
        }

        # Only add region if specified
        if aws_region:
            client_config['region_name'] = aws_region

        # Add S3 endpoint (required)
        client_config['endpoint_url'] = s3_endpoint
        self.logger.info(f"Using S3 endpoint: {s3_endpoint}")

        # Add SSL verification settings (default: disabled)
        verify_ssl = os.getenv('AWS_VERIFY_SSL', 'false').lower() == 'true'
        ca_bundle = os.getenv('S3_CA_BUNDLE')

        if not verify_ssl:
            # SSL verification is disabled - always use False regardless of CA bundle
            client_config['verify'] = False
            self.logger.debug("SSL verification is disabled (default)")
            if ca_bundle:
                self.logger.warning(f"S3_CA_BUNDLE is set ({ca_bundle}) but SSL verification is disabled - CA bundle will be ignored")
        else:
            # SSL verification is enabled
            if ca_bundle:
                # Use custom CA bundle for verification
                client_config['verify'] = ca_bundle
                self.logger.info(f"SSL verification is enabled with custom CA Bundle: {ca_bundle}")
            else:
                # Use default system CA certificates
                client_config['verify'] = True
                self.logger.info("SSL verification is enabled with system CA certificates")

        try:
            self.s3_client = boto3.client('s3', **client_config)
            self.logger.debug("S3 client initialized successfully")
        except Exception as e:
            self.logger.error(f"Failed to initialize S3 client: {e}")
            sys.exit(1)

    def validate_lifecycle_config(self, config: Dict[str, Any]) -> bool:
        """Validate S3 lifecycle configuration.

        Args:
            config: Lifecycle configuration dictionary

        Returns:
            True if valid, False otherwise
        """
        if not config:
            return True  # Empty/null config is valid

        # Check for required Rules array
        if 'Rules' not in config:
            self.logger.error("Lifecycle configuration must have 'Rules' array")
            return False

        rules = config['Rules']
        if not isinstance(rules, list):
            self.logger.error("'Rules' must be an array")
            return False

        # Validate each rule
        for i, rule in enumerate(rules):
            if not isinstance(rule, dict):
                self.logger.error(f"Rule at index {i} must be an object")
                return False

            # Check required fields
            if 'ID' not in rule:
                self.logger.error(f"Rule at index {i} missing required 'ID' field")
                return False

            if 'Status' not in rule:
                self.logger.error(f"Rule at index {i} missing required 'Status' field")
                return False

            # Validate Status field
            if rule['Status'] not in ['Enabled', 'Disabled']:
                self.logger.error(f"Rule at index {i} has invalid Status '{rule['Status']}' (must be 'Enabled' or 'Disabled')")
                return False

        return True

    def merge_lifecycle_configs(self, local_config: Dict[str, Any],
                              remote_config: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        """Merge local and remote lifecycle configurations intelligently.

        Merge Logic:
        - If remote has no configuration: use local configuration entirely
        - If remote has configuration:
          - Remote rules without matching local rule ID: keep remote rules
          - Remote rules with matching local rule ID: override with local rules
          - Local rules not in remote: add to final configuration

        Args:
            local_config: Local lifecycle configuration
            remote_config: Remote lifecycle configuration (can be None)

        Returns:
            Merged configuration dictionary
        """
        self.logger.debug("Starting lifecycle configuration merge")
        self.logger.debug(f"Local config: {json.dumps(local_config, indent=2)}")
        self.logger.debug(f"Remote config: {json.dumps(remote_config, indent=2) if remote_config else 'None'}")

        # If remote config is None or empty, use local config entirely
        if not remote_config:
            self.logger.debug("No remote configuration found, using local configuration")
            return local_config

        # Extract rules arrays from both configurations
        local_rules = local_config.get('Rules', [])
        remote_rules = remote_config.get('Rules', [])

        self.logger.debug(f"Local rules count: {len(local_rules)}")
        self.logger.debug(f"Remote rules count: {len(remote_rules)}")

        # Step 1: Start with all local rules (these will override any remote rules with same ID)
        merged_rules = local_rules.copy()
        local_rule_ids = {rule['ID'] for rule in local_rules}

        self.logger.debug(f"Local rule IDs: {local_rule_ids}")

        # Step 2: Add remote rules that don't have matching local rule IDs
        for remote_rule in remote_rules:
            remote_rule_id = remote_rule['ID']

            if remote_rule_id not in local_rule_ids:
                # Remote rule doesn't exist in local, add it to merged rules
                merged_rules.append(remote_rule)
                self.logger.debug(f"Adding remote rule ID '{remote_rule_id}' (not in local config)")
            else:
                self.logger.debug(f"Skipping remote rule ID '{remote_rule_id}' (overridden by local config)")

        # Step 3: Build final configuration using local config as base
        merged_config = local_config.copy()
        merged_config['Rules'] = merged_rules

        self.logger.debug(f"Final merged rules count: {len(merged_rules)}")
        self.logger.debug("Merge completed successfully")

        return merged_config

    def get_current_lifecycle_config(self, bucket_name: str) -> Optional[Dict[str, Any]]:
        """Get current lifecycle configuration from S3 bucket.

        Args:
            bucket_name: S3 bucket name

        Returns:
            Current lifecycle configuration or None if none exists
        """
        try:
            self.logger.debug(f"Getting lifecycle configuration for bucket: {bucket_name}")
            response = self.s3_client.get_bucket_lifecycle_configuration(Bucket=bucket_name)

            # Remove ResponseMetadata and return only the configuration
            config = {k: v for k, v in response.items() if k != 'ResponseMetadata'}
            self.logger.debug(f"Retrieved lifecycle configuration: {json.dumps(config, indent=2)}")
            return config

        except ClientError as e:
            error_code = e.response['Error']['Code']
            if error_code == 'NoSuchLifecycleConfiguration':
                self.logger.info("No existing lifecycle configuration found")
                return None
            else:
                self.logger.error(f"Failed to get lifecycle configuration: {e}")
                raise
        except Exception as e:
            self.logger.error(f"Unexpected error getting lifecycle configuration: {e}")
            raise

    def apply_lifecycle_config(self, bucket_name: str, config: Dict[str, Any]) -> bool:
        """Apply lifecycle configuration to S3 bucket.

        Args:
            bucket_name: S3 bucket name
            config: Lifecycle configuration to apply

        Returns:
            True if successful, False otherwise
        """
        try:
            self.logger.debug(f"Applying lifecycle configuration to bucket: {bucket_name}")
            self.logger.debug(f"Configuration payload: {json.dumps(config, indent=2)}")

            self.s3_client.put_bucket_lifecycle_configuration(
                Bucket=bucket_name,
                LifecycleConfiguration=config
            )

            self.logger.info(Colors.green("SUCCESS: Lifecycle configuration updated successfully"))
            return True

        except ClientError as e:
            self.logger.error(Colors.red(f"ERROR: Failed to update lifecycle configuration: {e}"))
            return False
        except Exception as e:
            self.logger.error(Colors.red(f"ERROR: Unexpected error applying lifecycle configuration: {e}"))
            return False



    def load_config_file(self, config_file: str) -> Dict[str, Any]:
        """Load lifecycle configuration from file.

        Args:
            config_file: Path to configuration file

        Returns:
            Configuration dictionary
        """
        try:
            with open(config_file, 'r') as f:
                config = json.load(f)

            if not self.validate_lifecycle_config(config):
                raise ValueError("Invalid lifecycle configuration")

            self.logger.info("Expected lifecycle configuration loaded and validated")
            return config

        except FileNotFoundError:
            self.logger.error(f"Lifecycle config file not found: {config_file}")
            raise
        except json.JSONDecodeError as e:
            self.logger.error(f"Invalid JSON in lifecycle config file: {config_file} - {e}")
            raise
        except Exception as e:
            self.logger.error(f"Failed to load config file: {e}")
            raise

    def apply_lifecycle_management(self, bucket_name: str, config_file: str) -> bool:
        """Apply lifecycle management to a bucket with intelligent merging.

        Args:
            bucket_name: S3 bucket name
            config_file: Path to local configuration file

        Returns:
            True if successful, False otherwise
        """
        self.logger.info("Starting S3 Lifecycle Check for Single Bucket")
        self.logger.info("=" * 50)
        self.logger.info(f"Timestamp: {datetime.now()}")
        self.logger.info("Script Version: 2.1 (Python with boto3)")

        # Display configuration
        self.logger.info("")
        self.logger.info("Configuration:")
        self.logger.info(f"   Bucket: {bucket_name}")
        self.logger.info(f"   Lifecycle Config File: {config_file}")
        self.logger.info(f"   Endpoint: {os.getenv('S3_ENDPOINT')}")
        self.logger.info(f"   Access Key: {os.getenv('AWS_ACCESS_KEY_ID', '')[:8]}***")
        self.logger.info(f"   Region: {os.getenv('AWS_DEFAULT_REGION') or 'default'}")

        # Load expected configuration
        self.logger.info("")
        self.logger.info("Loading expected lifecycle configuration...")
        try:
            local_config = self.load_config_file(config_file)
            self.logger.debug("Local configuration loaded:")
            self.logger.debug(json.dumps(local_config, indent=2))
        except Exception:
            return False

        # Get current configuration
        self.logger.info("")
        self.logger.info("Getting current lifecycle configuration...")
        try:
            remote_config = self.get_current_lifecycle_config(bucket_name)
            if remote_config:
                self.logger.debug("Remote configuration retrieved:")
                self.logger.debug(json.dumps(remote_config, indent=2))
            else:
                self.logger.debug("No remote configuration found")
        except Exception:
            return False

        # Merge configurations
        self.logger.info("")
        self.logger.info("Merging configurations...")
        merged_config = self.merge_lifecycle_configs(local_config, remote_config)
        self.logger.debug("Final merged configuration:")
        self.logger.debug(json.dumps(merged_config, indent=2))

        # Compare current with merged configuration
        if self._configs_equal(remote_config, merged_config):
            self.logger.info(Colors.green("SUCCESS: Lifecycle configuration is up to date (no changes needed after merge)"))
            config_updated = False
        else:
            self.logger.info("INFO: Lifecycle configuration will be updated with merged rules")
            self.logger.info("")
            self.logger.info("Merged configuration to apply:")
            self.logger.info(json.dumps(merged_config, indent=2))

            if remote_config:
                self.logger.info("")
                self.logger.info("Current remote configuration:")
                self.logger.info(json.dumps(remote_config, indent=2))
            else:
                self.logger.info("")
                self.logger.info("Current remote configuration: No lifecycle configuration exists")

            # Create backup if current config exists
            if remote_config:
                backup_file = f"/tmp/lifecycle-backup-{bucket_name}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
                try:
                    with open(backup_file, 'w') as f:
                        json.dump(remote_config, f, indent=2)
                    self.logger.info(f"Current configuration backed up to: {backup_file}")
                except Exception as e:
                    self.logger.warning(f"Failed to create backup: {e}")

            # Apply new configuration
            self.logger.info("")
            self.logger.info("Updating lifecycle configuration...")

            if not self.apply_lifecycle_config(bucket_name, merged_config):
                return False

            # Verify the update
            self.logger.info("Verifying update...")
            try:
                updated_config = self.get_current_lifecycle_config(bucket_name)

                # Debug log: show the final effective configuration from S3
                self.logger.debug("Final effective configuration from S3:")
                if updated_config:
                    self.logger.debug(json.dumps(updated_config, indent=2))
                else:
                    self.logger.debug("No lifecycle configuration found in S3")

                if self._configs_equal(updated_config, merged_config):
                    self.logger.info(Colors.green("SUCCESS: Configuration update verified"))
                    config_updated = True
                else:
                    self.logger.error(Colors.red("ERROR: Configuration update verification failed"))
                    return False
            except Exception:
                self.logger.error(Colors.red("ERROR: Failed to verify configuration update"))
                return False

        # Print summary
        self.logger.info("")
        self.logger.info(f"Lifecycle housekeeping completed for bucket: {bucket_name}")
        self.logger.info("=" * 50)
        self.logger.info("Summary:")
        self.logger.info(f"  - Bucket: {bucket_name}")
        if config_updated:
            self.logger.info("  - Configuration Status: UPDATED")
        else:
            self.logger.info("  - Configuration Status: UP TO DATE")
        self.logger.info("  - Status: SUCCESS")
        self.logger.info(f"  - Timestamp: {datetime.now()}")

        return True

    def _configs_equal(self, config1: Optional[Dict[str, Any]],
                      config2: Optional[Dict[str, Any]]) -> bool:
        """Compare two configurations for equality.

        Args:
            config1: First configuration
            config2: Second configuration

        Returns:
            True if configurations are equal, False otherwise
        """
        # Convert to normalized JSON strings for comparison
        def normalize_config(config):
            if not config:
                return None
            return json.dumps(config, sort_keys=True, separators=(',', ':'))

        return normalize_config(config1) == normalize_config(config2)

    def run_tests(self) -> bool:
        """Run comprehensive tests for the lifecycle merge functionality.

        Returns:
            True if all tests pass, False otherwise
        """
        self.logger.info("Testing S3 Lifecycle Policy Merge Functionality")
        self.logger.info("=" * 50)

        test_cases = [
            self._test_case_1_no_remote_config,
            self._test_case_2_no_conflicts,
            self._test_case_3_with_conflicts,
            self._test_case_4_validation
        ]

        for i, test_case in enumerate(test_cases, 1):
            try:
                self.logger.info("")
                if not test_case():
                    self.logger.error(Colors.red(f"FAILED: Test Case {i} failed"))
                    return False
                self.logger.info(Colors.green(f"PASSED: Test Case {i} passed"))
            except Exception as e:
                self.logger.error(Colors.red(f"FAILED: Test Case {i} failed with exception: {e}"))
                return False

        self.logger.info("")
        self.logger.info(Colors.green("SUCCESS: All tests passed!"))
        self.logger.info("The merge functionality is working correctly.")
        return True

    def _test_case_1_no_remote_config(self) -> bool:
        """Test Case 1: Remote has no configuration."""
        self.logger.info("Test Case 1: Remote has no configuration")
        self.logger.info("-" * 40)

        local_config = {
            "Rules": [
                {
                    "ID": "local-rule-1",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "logs/"},
                    "Expiration": {"Days": 30}
                }
            ]
        }

        remote_config = None

        self.logger.info(f"Local config: {json.dumps(local_config)}")
        self.logger.info(f"Remote config: {remote_config}")

        result = self.merge_lifecycle_configs(local_config, remote_config)
        self.logger.info("Merged result:")
        self.logger.info(json.dumps(result, indent=2))

        # Verify result equals local config
        return self._configs_equal(result, local_config)

    def _test_case_2_no_conflicts(self) -> bool:
        """Test Case 2: Remote has config, no ID conflicts."""
        self.logger.info("Test Case 2: Remote has config, no ID conflicts")
        self.logger.info("-" * 48)

        local_config = {
            "Rules": [
                {
                    "ID": "local-rule-1",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "logs/"},
                    "Expiration": {"Days": 30}
                }
            ]
        }

        remote_config = {
            "Rules": [
                {
                    "ID": "remote-rule-1",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "data/"},
                    "Expiration": {"Days": 60}
                }
            ]
        }

        self.logger.info(f"Local config: {json.dumps(local_config)}")
        self.logger.info(f"Remote config: {json.dumps(remote_config)}")

        result = self.merge_lifecycle_configs(local_config, remote_config)
        self.logger.info("Merged result:")
        self.logger.info(json.dumps(result, indent=2))

        # Verify result has both rules
        if len(result['Rules']) != 2:
            return False

        rule_ids = {rule['ID'] for rule in result['Rules']}
        return rule_ids == {'local-rule-1', 'remote-rule-1'}

    def _test_case_3_with_conflicts(self) -> bool:
        """Test Case 3: Remote has config with ID conflict."""
        self.logger.info("Test Case 3: Remote has config with ID conflict")
        self.logger.info("-" * 48)

        local_config = {
            "Rules": [
                {
                    "ID": "shared-rule",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "logs/"},
                    "Expiration": {"Days": 30}
                }
            ]
        }

        remote_config = {
            "Rules": [
                {
                    "ID": "shared-rule",
                    "Status": "Disabled",
                    "Filter": {"Prefix": "old-logs/"},
                    "Expiration": {"Days": 90}
                },
                {
                    "ID": "remote-only-rule",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "backups/"},
                    "Expiration": {"Days": 365}
                }
            ]
        }

        self.logger.info(f"Local config: {json.dumps(local_config)}")
        self.logger.info(f"Remote config: {json.dumps(remote_config)}")

        result = self.merge_lifecycle_configs(local_config, remote_config)
        self.logger.info("Merged result:")
        self.logger.info(json.dumps(result, indent=2))

        # Verify that local rule overrode remote rule with same ID
        shared_rule = next((rule for rule in result['Rules'] if rule['ID'] == 'shared-rule'), None)
        if not shared_rule or shared_rule['Expiration']['Days'] != 30:
            self.logger.error("Local rule did not override remote rule correctly")
            return False

        # Verify that remote-only rule was preserved
        remote_only_rule = next((rule for rule in result['Rules'] if rule['ID'] == 'remote-only-rule'), None)
        if not remote_only_rule:
            self.logger.error("Remote-only rule was not preserved")
            return False

        self.logger.info(Colors.green("SUCCESS: Local rule correctly overrode remote rule"))
        self.logger.info(Colors.green("SUCCESS: Remote-only rule was preserved"))

        return True

    def _test_case_4_validation(self) -> bool:
        """Test Case 4: Configuration validation."""
        self.logger.info("Test Case 4: Configuration validation")
        self.logger.info("-" * 40)

        # Test valid configuration
        valid_config = {
            "Rules": [
                {
                    "ID": "test-rule",
                    "Status": "Enabled",
                    "Filter": {"Prefix": "test/"},
                    "Expiration": {"Days": 30}
                }
            ]
        }

        if not self.validate_lifecycle_config(valid_config):
            self.logger.error("Valid configuration was rejected")
            return False

        # Test invalid configurations
        invalid_configs = [
            {"Rules": [{"Status": "Enabled"}]},  # Missing ID
            {"Rules": [{"ID": "test"}]},         # Missing Status
            {"Rules": [{"ID": "test", "Status": "Invalid"}]},  # Invalid Status
            {"NotRules": []},                    # Missing Rules array
        ]

        for i, invalid_config in enumerate(invalid_configs):
            if self.validate_lifecycle_config(invalid_config):
                self.logger.error(f"Invalid configuration {i+1} was accepted")
                return False

        self.logger.info(Colors.green("SUCCESS: Configuration validation working correctly"))
        return True


def main():
    """Main function to handle command line arguments and execute actions."""
    parser = argparse.ArgumentParser(
        description='S3 Lifecycle Configuration Manager',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Apply lifecycle configuration to a bucket
  python3 s3_lifecycle_manager.py apply my-bucket /path/to/config.json

  # Apply with debug output
  python3 s3_lifecycle_manager.py apply my-bucket /path/to/config.json --debug

  # Run tests
  python3 s3_lifecycle_manager.py test

  # Run tests with debug output
  python3 s3_lifecycle_manager.py test --debug

Environment Variables:
  AWS_ACCESS_KEY_ID      - AWS access key ID (required)
  AWS_SECRET_ACCESS_KEY  - AWS secret access key (required)
  S3_ENDPOINT            - S3 endpoint URL (required)
  AWS_DEFAULT_REGION     - AWS region (optional)
  AWS_VERIFY_SSL         - Verify SSL certificates (default: false)
  S3_CA_BUNDLE          - Path to CA certificate bundle (optional)
  DEBUG                  - Enable debug mode (true/false, default: false)

Dependencies:
  pip install boto3
        """
    )

    parser.add_argument(
        '--debug',
        action='store_true',
        help='Enable debug mode with verbose output'
    )

    subparsers = parser.add_subparsers(dest='command', help='Available commands')

    # Apply command
    apply_parser = subparsers.add_parser('apply', help='Apply lifecycle configuration to S3 bucket')
    apply_parser.add_argument('bucket_name', help='S3 bucket name')
    apply_parser.add_argument('config_file', help='Path to lifecycle configuration JSON file')

    # Test command
    test_parser = subparsers.add_parser('test', help='Run functionality tests')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Check for DEBUG environment variable if --debug flag is not set
    debug_mode = args.debug
    if not debug_mode:
        debug_env = os.getenv('DEBUG', 'false').lower()
        debug_mode = debug_env in ('true', '1', 'yes', 'on')
        if debug_mode:
            print("Debug mode enabled via DEBUG environment variable")

    try:
        if args.command == 'apply':
            # Create manager instance with AWS config
            manager = S3LifecycleManager(debug=debug_mode)
            success = manager.apply_lifecycle_management(args.bucket_name, args.config_file)
            sys.exit(0 if success else 1)

        elif args.command == 'test':
            # Create manager instance without AWS config for testing
            manager = S3LifecycleManager(debug=debug_mode, skip_aws_config=True)
            success = manager.run_tests()
            sys.exit(0 if success else 1)

    except KeyboardInterrupt:
        print("\nOperation cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        if debug_mode:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
#!/bin/bash

# Script for checking S3 object lifecycle for a single bucket
# This script is designed to be used with one bucket per CronJob
# Usage: s3-lifecycle-check-single.sh <lifecycle-config-file-path>

set -euo pipefail

# Enable debug mode if DEBUG environment variable is set to true
if [[ "${DEBUG:-false}" == "true" ]]; then
    echo "🐛 DEBUG MODE ENABLED"
    set -x  # Enable command tracing
fi

echo "Starting S3 Lifecycle Check for Single Bucket"
echo "================================================"
echo "Timestamp: $(date)"
echo "Script Version: 1.0"

# Check if lifecycle config file path is provided as argument
if [[ $# -ne 1 ]]; then
    echo -e "\033[31mError: Lifecycle config file path must be provided as argument\033[0m"
    echo "Usage: $0 <lifecycle-config-file-path>"
    exit 1
fi

LIFECYCLE_CONFIG_FILE="$1"

# Check required environment variables
required_vars=("S3_BUCKET_NAME" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "S3_ENDPOINT")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "\033[31mError: Environment variable $var is not set\033[0m"
        exit 1
    fi
done

# Check if lifecycle config file exists
if [[ ! -f "${LIFECYCLE_CONFIG_FILE}" ]]; then
    echo -e "\033[31mError: Lifecycle config file not found: ${LIFECYCLE_CONFIG_FILE}\033[0m"
    exit 1
fi

# Display configuration
echo ""
echo "Configuration:"
echo "   Bucket: ${S3_BUCKET_NAME}"
echo "   Lifecycle Config File: ${LIFECYCLE_CONFIG_FILE}"
echo "   Endpoint: ${S3_ENDPOINT}"
echo "   Access Key: ${AWS_ACCESS_KEY_ID:0:8}***"
if [[ "${DEBUG:-false}" == "true" ]]; then
    echo "   DEBUG MODE: ${DEBUG}"
    echo "   Script Arguments: $@"
    echo "   PWD: $(pwd)"
    echo "   Available files in /lifecycle-configs/:"
    ls -la /lifecycle-configs/ 2>/dev/null || echo "   Directory not found"
fi

# AWS region will be determined by AWS CLI default configuration or instance metadata

# Configure bucket-specific CA Bundle if provided
if [[ -n "${S3_CA_BUNDLE:-}" ]]; then
    export AWS_CA_BUNDLE="${S3_CA_BUNDLE}"
    echo "   CA Bundle: ${S3_CA_BUNDLE}"
fi

echo ""

# Configure AWS CLI for this bucket's endpoint
aws_cli_opts=""
if [[ -n "${S3_ENDPOINT}" && "${S3_ENDPOINT}" != "https://s3.amazonaws.com" ]]; then
    aws_cli_opts="--endpoint-url ${S3_ENDPOINT}"
fi

if [[ "${DEBUG:-false}" == "true" ]]; then
    echo "🐛 DEBUG: AWS CLI options: ${aws_cli_opts}"
    echo "🐛 DEBUG: AWS CLI version: $(aws --version 2>&1 || echo 'aws command not found')"
    echo "🐛 DEBUG: Testing AWS CLI configuration..."
fi

echo "Testing bucket accessibility..."

# Test bucket access
if ! aws s3 ls "s3://${S3_BUCKET_NAME}" ${aws_cli_opts} > /dev/null 2>&1; then
    echo -e "\033[31mError: Cannot access bucket ${S3_BUCKET_NAME}\033[0m"
    echo "   Please check:"
    echo "   - Bucket name is correct"
    echo "   - AWS credentials have proper permissions"
    echo "   - Network connectivity to S3 endpoint"
    exit 1
fi

echo "Bucket ${S3_BUCKET_NAME} is accessible"

echo ""
echo "Loading expected lifecycle configuration..."

# Read expected lifecycle configuration from file
if ! expected_config=$(cat "${LIFECYCLE_CONFIG_FILE}"); then
    echo -e "\033[31mError: Failed to read lifecycle config file: ${LIFECYCLE_CONFIG_FILE}\033[0m"
    exit 1
fi

# Validate expected config is valid JSON
if ! echo "$expected_config" | jq . > /dev/null 2>&1; then
    echo -e "\033[31mError: Invalid JSON in lifecycle config file: ${LIFECYCLE_CONFIG_FILE}\033[0m"
    exit 1
fi

echo "Expected lifecycle configuration loaded and validated"

echo ""
echo "Getting current lifecycle configuration..."

# Get current lifecycle configuration
current_config=$(aws s3api get-bucket-lifecycle-configuration \
    --bucket "${S3_BUCKET_NAME}" \
    ${aws_cli_opts} 2>/dev/null || echo "null")

echo ""
echo "Comparing configurations..."

# Normalize configurations for comparison (remove whitespace and sort keys)
normalized_expected=$(echo "$expected_config" | jq -S -c .)
normalized_current="null"

if [[ "$current_config" != "null" && -n "$current_config" ]]; then
    normalized_current=$(echo "$current_config" | jq -S -c .)
fi

if [[ "${DEBUG:-false}" == "true" ]]; then
    echo "🐛 DEBUG: Normalized expected config: $normalized_expected"
    echo "🐛 DEBUG: Normalized current config: $normalized_current"
fi

# Compare configurations
if [[ "$normalized_current" == "$normalized_expected" ]]; then
    echo "✅ Lifecycle configuration is up to date"
    config_matches=true
else
    echo "❌ Lifecycle configuration differs from expected"
    echo ""
    echo "Expected configuration:"
    echo "$expected_config" | jq .
    echo ""
    if [[ "$current_config" != "null" && -n "$current_config" ]]; then
        echo "Current configuration:"
        echo "$current_config" | jq .
    else
        echo "Current configuration: No lifecycle configuration exists"
    fi
    config_matches=false
fi

# Update configuration if needed
if [[ "$config_matches" != "true" ]]; then
    echo ""
    echo "Updating lifecycle configuration..."

    # Create a backup of current config (if exists)
    if [[ "$current_config" != "null" && -n "$current_config" ]]; then
        backup_file="/tmp/lifecycle-backup-${S3_BUCKET_NAME}-$(date +%Y%m%d-%H%M%S).json"
        echo "$current_config" > "$backup_file"
        echo "Current configuration backed up to: $backup_file"
    fi

    # Apply new configuration
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo "🐛 DEBUG: Executing command: aws s3api put-bucket-lifecycle-configuration --bucket ${S3_BUCKET_NAME} ${aws_cli_opts}"
        echo "🐛 DEBUG: Configuration payload:"
        echo "$expected_config" | jq .
    fi

    if aws s3api put-bucket-lifecycle-configuration \
        --bucket "${S3_BUCKET_NAME}" \
        --lifecycle-configuration "$(echo "$expected_config")" \
        ${aws_cli_opts}; then
        echo "✅ Lifecycle configuration updated successfully"

        # Verify the update
        echo "Verifying update..."
        updated_config=$(aws s3api get-bucket-lifecycle-configuration \
            --bucket "${S3_BUCKET_NAME}" \
            ${aws_cli_opts} 2>/dev/null || echo "null")

        normalized_updated=$(echo "$updated_config" | jq -S -c .)
        if [[ "$normalized_updated" == "$normalized_expected" ]]; then
            echo "✅ Configuration update verified"
        else
            echo -e "\033[31m❌ Configuration update verification failed\033[0m"
            exit 1
        fi
    else
        echo -e "\033[31m❌ Failed to update lifecycle configuration\033[0m"
        exit 1
    fi
fi

echo ""
echo "Listing objects in bucket..."

# List objects and get count
object_count=$(aws s3 ls "s3://${S3_BUCKET_NAME}" --recursive ${aws_cli_opts} | wc -l)

echo "Total objects in bucket: ${object_count}"

if [[ "$object_count" -eq 0 ]]; then
    echo "INFO: Bucket is empty - no objects to check"
else
    echo ""
    echo "Sample objects (first 10):"
    aws s3 ls "s3://${S3_BUCKET_NAME}" --recursive ${aws_cli_opts} | head -10
fi

echo ""
echo "Lifecycle housekeeping completed for bucket: ${S3_BUCKET_NAME}"
echo "================================================"
echo "Summary:"
echo "  - Bucket: ${S3_BUCKET_NAME}"
echo "  - Object Count: ${object_count}"
if [[ "$config_matches" == "true" ]]; then
    echo "  - Configuration Status: UP TO DATE"
else
    echo "  - Configuration Status: UPDATED"
fi
echo "  - Status: SUCCESS"
echo "  - Timestamp: $(date)"

exit 0
#!/bin/bash

# Multi-Bucket E2E Test Runner for S3 Housekeeping
# This script runs the e2e tests with multi-bucket configuration

set -euo pipefail

# Set environment variable to enable multi-bucket testing
export USE_MULTI_BUCKET=true

echo "🚀 Starting Multi-Bucket S3 Housekeeping E2E Tests"
echo "=================================================="
echo "This test will verify:"
echo "  - 4 buckets: test-bucket-1, test-bucket-2, logs-bucket, my-bucket"
echo "  - 4 individual CronJobs (one per bucket)"
echo "  - Different lifecycle configurations per bucket"
echo ""

# Run the main e2e test script
exec "$(dirname "$0")/run-e2e-tests.sh" "$@"
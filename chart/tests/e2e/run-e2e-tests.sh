#!/bin/bash

# E2E Test Script for S3 Housekeeping with MinIO
# This script tests the complete lifecycle management functionality

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration - endpoint will be set dynamically
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://localhost:9000}"
MINIO_ACCESS_KEY="admin"
MINIO_SECRET_KEY="password"
TEST_NAMESPACE="s3-housekeeping-e2e"

# Test results tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
    PASSED_TESTS=$((PASSED_TESTS + 1))
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

run_test() {
    local test_name="$1"
    local test_func="$2"

    echo ""
    echo "=========================================="
    echo "🧪 Running test: $test_name"
    echo "=========================================="

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if $test_func; then
        log_success "Test '$test_name' passed"
    else
        log_error "Test '$test_name' failed"
        return 1
    fi
}

# Test 1: Create Kubernetes secrets for MinIO credentials
test_create_secrets() {
    log_info "Creating Kubernetes secrets for MinIO credentials..."

    # Create namespace
    kubectl create namespace ${TEST_NAMESPACE} || true

    # Create secret for MinIO credentials
    kubectl create secret generic minio-credentials \
        --from-literal=accesskey=${MINIO_ACCESS_KEY} \
        --from-literal=secretkey=${MINIO_SECRET_KEY} \
        --namespace=${TEST_NAMESPACE} \
        --dry-run=client -o yaml | kubectl apply -f -

    # Verify secret exists
    if kubectl get secret minio-credentials -n ${TEST_NAMESPACE} > /dev/null 2>&1; then
        log_success "MinIO credentials secret created successfully"
        return 0
    else
        log_error "Failed to create MinIO credentials secret"
        return 1
    fi
}

# Test 2: Deploy S3 Housekeeping chart
test_deploy_chart() {
    log_info "Deploying S3 Housekeeping chart..."

    # Check if multi-bucket config should be used
    local values_file="chart/tests/e2e/values-e2e-test.yaml"
    if [[ "${USE_MULTI_BUCKET:-false}" == "true" ]]; then
        values_file="chart/tests/e2e/values-multi-bucket-e2e.yaml"
        log_info "Using multi-bucket configuration"
    fi

    # Use the e2e test values
    if helm install s3-housekeeping-e2e ./chart \
        --namespace=${TEST_NAMESPACE} \
        --values=${values_file} \
        --wait --timeout=5m; then
        log_success "S3 Housekeeping chart deployed successfully"
    else
        log_error "Failed to deploy S3 Housekeeping chart"
        return 1
    fi

    # Verify CronJobs are created
    local expected_cronjobs=1
    if [[ "${USE_MULTI_BUCKET:-false}" == "true" ]]; then
        expected_cronjobs=4  # test-bucket-1, test-bucket-2, logs-bucket, my-bucket
    fi

    local cronjob_count=$(kubectl get cronjobs -n ${TEST_NAMESPACE} --no-headers | wc -l)
    if [[ $cronjob_count -eq $expected_cronjobs ]]; then
        log_success "$expected_cronjobs CronJob(s) created successfully"

        # List the created CronJobs
        log_info "Created CronJobs:"
        kubectl get cronjobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name"
        return 0
    else
        log_error "Expected $expected_cronjobs CronJob(s), found $cronjob_count"
        return 1
    fi
}

# Test 3: Manually trigger jobs and verify lifecycle configuration
test_lifecycle_application() {
    log_info "Testing lifecycle configuration application..."

    # Get CronJob names
    local cronjobs=($(kubectl get cronjobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name"))
    local expected_jobs=${#cronjobs[@]}

    log_info "Found ${expected_jobs} CronJob(s) to trigger"

    for cronjob in "${cronjobs[@]}"; do
        log_info "Creating manual job from CronJob: $cronjob"

        # Create manual job from CronJob
        kubectl create job "${cronjob}-manual-$(date +%s)" \
            --from=cronjob/${cronjob} \
            --namespace=${TEST_NAMESPACE}
    done

    # Wait for jobs to complete with 5-minute timeout
    log_info "Waiting for ${expected_jobs} job(s) to complete (timeout: 5 minutes)..."

    local completed_jobs=0
    local jobs=($(kubectl get jobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name"))

    for job in "${jobs[@]}"; do
        log_info "Waiting for job $job to complete..."
        if kubectl wait --for=condition=complete job/${job} -n ${TEST_NAMESPACE} --timeout=300s; then
            log_success "Job $job completed successfully"
            completed_jobs=$((completed_jobs + 1))

            # Always show job logs for debugging
            log_info "Job $job logs:"
            kubectl logs job/${job} -n ${TEST_NAMESPACE} || true
        else
            log_error "Job $job failed or timed out"
            # Show job logs for debugging
            log_info "Job $job logs:"
            kubectl logs job/${job} -n ${TEST_NAMESPACE} || true
        fi
    done

    if [[ $completed_jobs -eq $expected_jobs ]]; then
        log_success "All $expected_jobs job(s) completed successfully"
        return 0
    else
        log_error "Only $completed_jobs out of $expected_jobs job(s) completed successfully"
        return 1
    fi
}

# Test 4: Verify lifecycle configs using temporary pod
test_verify_lifecycle_configs() {
    log_info "Verifying lifecycle configurations using temporary pod..."

    # Define buckets to check based on configuration
    local buckets=("my-bucket")
    if [[ "${USE_MULTI_BUCKET:-false}" == "true" ]]; then
        buckets=("test-bucket-1" "test-bucket-2" "logs-bucket" "my-bucket")
    fi

    local success_count=0
    local total_buckets=${#buckets[@]}

    for bucket in "${buckets[@]}"; do
        log_info "Checking lifecycle configuration for bucket: $bucket"

        # Create temporary pod to check lifecycle configuration
        if kubectl run debug-lifecycle-check-${bucket} --rm -i --tty \
            --image=ghcr.io/sn0rt/utils:utils-v0.0.2 \
            --env="AWS_ACCESS_KEY_ID=admin" \
            --env="AWS_SECRET_ACCESS_KEY=password" \
            --env="AWS_DEFAULT_REGION=us-east-1" \
            --restart=Never \
            --timeout=60s \
            -- bash -c "
                echo 'Configuring AWS CLI for bucket ${bucket}...'
                aws configure set aws_access_key_id admin
                aws configure set aws_secret_access_key password
                aws configure set default.region us-east-1

                echo 'Testing MinIO connection...'
                aws s3 ls --endpoint-url http://minio.minio.svc.cluster.local:9000

                echo 'Checking bucket ${bucket}...'
                aws s3 ls s3://${bucket} --endpoint-url http://minio.minio.svc.cluster.local:9000

                echo 'Getting lifecycle configuration for ${bucket}...'
                lifecycle_config=\$(aws s3api get-bucket-lifecycle-configuration \
                    --bucket ${bucket} \
                    --endpoint-url http://minio.minio.svc.cluster.local:9000 2>/dev/null || echo 'null')

                echo \"Retrieved config for ${bucket}: \$lifecycle_config\"

                # Check if configuration exists and has enabled rules
                if [[ \"\$lifecycle_config\" == \"null\" ]] || [[ \"\$lifecycle_config\" == \"\" ]]; then
                    echo 'ERROR: No lifecycle configuration found for ${bucket}'
                    exit 1
                elif echo \"\$lifecycle_config\" | grep -q '\"Rules\"' && echo \"\$lifecycle_config\" | grep -q '\"Status\".*\"Enabled\"'; then
                    echo 'SUCCESS: Lifecycle rules found and enabled for ${bucket}'
                    echo \"\$lifecycle_config\"
                    exit 0
                else
                    echo 'ERROR: Lifecycle configuration exists but no enabled rules found for ${bucket}'
                    echo \"Current config: \$lifecycle_config\"
                    exit 1
                fi
            "; then
            log_success "Bucket '$bucket' has active lifecycle rules"
            success_count=$((success_count + 1))
        else
            log_error "Bucket '$bucket' has no active lifecycle rules or could not retrieve configuration"
        fi
    done

    if [[ $success_count -eq $total_buckets ]]; then
        log_success "All $total_buckets bucket(s) have active lifecycle rules"
        return 0
    else
        log_error "Only $success_count out of $total_buckets bucket(s) have active lifecycle rules"
        return 1
    fi
}

# Test 5: Test configuration updates (idempotency)
test_idempotency() {
    log_info "Testing configuration idempotency..."

    # Run the jobs again to verify they detect no changes needed
    local cronjobs=($(kubectl get cronjobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name"))
    local expected_jobs=${#cronjobs[@]}

    log_info "Creating idempotency test jobs for ${expected_jobs} CronJob(s)..."

    for cronjob in "${cronjobs[@]}"; do
        # Create another manual job
        kubectl create job "${cronjob}-idempotency-$(date +%s)" \
            --from=cronjob/${cronjob} \
            --namespace=${TEST_NAMESPACE}
    done

    # Wait for idempotency jobs to complete with 5-minute timeout
    log_info "Waiting for ${expected_jobs} idempotency job(s) to complete (timeout: 5 minutes)..."

    local idempotent_jobs=($(kubectl get jobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name" | grep idempotency))
    local success_count=0

    for job in "${idempotent_jobs[@]}"; do
        log_info "Waiting for idempotency job $job to complete..."
        if kubectl wait --for=condition=complete job/${job} -n ${TEST_NAMESPACE} --timeout=300s; then
            log_success "Idempotency job $job completed successfully"
            success_count=$((success_count + 1))
        else
            log_error "Idempotency job $job failed or timed out"
            kubectl logs job/${job} -n ${TEST_NAMESPACE} || true
        fi
    done

    if [[ $success_count -eq $expected_jobs ]]; then
        log_success "All $expected_jobs idempotency test(s) passed"
        return 0
    else
        log_error "Idempotency test failed: $success_count out of $expected_jobs job(s) succeeded"
        return 1
    fi
}

# Main test execution
main() {
    echo "🚀 Starting S3 Housekeeping E2E Tests"
    echo "======================================"
    echo "MinIO Endpoint: ${MINIO_ENDPOINT}"
    echo "Test Namespace: ${TEST_NAMESPACE}"
    echo ""

    # Run all tests
    run_test "Create Secrets" test_create_secrets
    run_test "Deploy Chart" test_deploy_chart
    run_test "Lifecycle Application" test_lifecycle_application
    run_test "Verify Lifecycle Configs" test_verify_lifecycle_configs
    run_test "Idempotency" test_idempotency

    # Summary
    echo ""
    echo "=========================================="
    echo "🏁 E2E Test Summary"
    echo "=========================================="
    echo "Total Tests: $TOTAL_TESTS"
    echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed: ${RED}$FAILED_TESTS${NC}"

    if [[ $FAILED_TESTS -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}🎉 All E2E tests passed successfully!${NC}"
        echo "The S3 Housekeeping chart is working correctly with MinIO."
        exit 0
    else
        echo ""
        echo -e "${RED}💥 Some E2E tests failed.${NC}"
        echo "Please check the logs above for details."

        # Note: Resources will be cleaned up when minikube is reset
        exit 1
    fi
}

# Run the main function
main "$@"
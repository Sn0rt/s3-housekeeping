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

# Test configuration
MINIO_ENDPOINT="http://localhost:9000"
MINIO_ACCESS_KEY="minioadmin"
MINIO_SECRET_KEY="minioadmin123"
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

# Test 1: Verify MinIO connectivity and buckets
test_minio_connectivity() {
    log_info "Testing MinIO connectivity and bucket creation..."

    # Test AWS CLI connection to MinIO
    if ! aws s3 ls --endpoint-url ${MINIO_ENDPOINT} > /dev/null 2>&1; then
        log_error "Cannot connect to MinIO at ${MINIO_ENDPOINT}"
        return 1
    fi

    # Check if test buckets exist
    local buckets=("test-bucket-1" "test-bucket-2" "test-bucket-3")
    for bucket in "${buckets[@]}"; do
        if aws s3 ls "s3://${bucket}" --endpoint-url ${MINIO_ENDPOINT} > /dev/null 2>&1; then
            log_success "Bucket '${bucket}' exists and is accessible"
        else
            log_error "Bucket '${bucket}' not found or not accessible"
            return 1
        fi
    done

    return 0
}

# Test 2: Create Kubernetes secrets for MinIO credentials
test_create_secrets() {
    log_info "Creating Kubernetes secrets for MinIO credentials..."

    # Create namespace
    kubectl create namespace ${TEST_NAMESPACE} || true

    # Create secrets for each bucket (simulating different credentials)
    kubectl create secret generic minio-credentials-1 \
        --from-literal=AWS_ACCESS_KEY_ID=${MINIO_ACCESS_KEY} \
        --from-literal=AWS_SECRET_ACCESS_KEY=${MINIO_SECRET_KEY} \
        --namespace=${TEST_NAMESPACE} \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic minio-credentials-2 \
        --from-literal=ACCESS_KEY=${MINIO_ACCESS_KEY} \
        --from-literal=SECRET_KEY=${MINIO_SECRET_KEY} \
        --namespace=${TEST_NAMESPACE} \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic minio-credentials-3 \
        --from-literal=accesskey=${MINIO_ACCESS_KEY} \
        --from-literal=secretkey=${MINIO_SECRET_KEY} \
        --namespace=${TEST_NAMESPACE} \
        --dry-run=client -o yaml | kubectl apply -f -

    # Verify secrets exist
    if kubectl get secret minio-credentials-1 -n ${TEST_NAMESPACE} > /dev/null 2>&1 && \
       kubectl get secret minio-credentials-2 -n ${TEST_NAMESPACE} > /dev/null 2>&1 && \
       kubectl get secret minio-credentials-3 -n ${TEST_NAMESPACE} > /dev/null 2>&1; then
        log_success "All MinIO credentials secrets created successfully"
        return 0
    else
        log_error "Failed to create one or more credentials secrets"
        return 1
    fi
}

# Test 3: Deploy S3 Housekeeping chart
test_deploy_chart() {
    log_info "Deploying S3 Housekeeping chart..."

    # Use the e2e test values
    if helm install s3-housekeeping-e2e ./chart \
        --namespace=${TEST_NAMESPACE} \
        --values=chart/tests/e2e/values-e2e-test.yaml \
        --wait --timeout=5m; then
        log_success "S3 Housekeeping chart deployed successfully"
    else
        log_error "Failed to deploy S3 Housekeeping chart"
        return 1
    fi

    # Verify CronJobs are created
    local cronjob_count=$(kubectl get cronjobs -n ${TEST_NAMESPACE} --no-headers | wc -l)
    if [[ $cronjob_count -eq 3 ]]; then
        log_success "All 3 CronJobs created successfully"
        return 0
    else
        log_error "Expected 3 CronJobs, found $cronjob_count"
        return 1
    fi
}

# Test 4: Manually trigger jobs and verify lifecycle configuration
test_lifecycle_application() {
    log_info "Testing lifecycle configuration application..."

    # Get CronJob names
    local cronjobs=($(kubectl get cronjobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name"))

    for cronjob in "${cronjobs[@]}"; do
        log_info "Creating manual job from CronJob: $cronjob"

        # Create manual job from CronJob
        kubectl create job "${cronjob}-manual-$(date +%s)" \
            --from=cronjob/${cronjob} \
            --namespace=${TEST_NAMESPACE}
    done

    # Wait for jobs to complete
    log_info "Waiting for jobs to complete..."
    sleep 30

    # Check job status
    local completed_jobs=0
    local jobs=($(kubectl get jobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name"))

    for job in "${jobs[@]}"; do
        local status=$(kubectl get job ${job} -n ${TEST_NAMESPACE} -o jsonpath='{.status.conditions[0].type}')
        if [[ "$status" == "Complete" ]]; then
            log_success "Job $job completed successfully"
            completed_jobs=$((completed_jobs + 1))
        else
            log_error "Job $job failed or is still running"
            # Show job logs for debugging
            kubectl logs job/${job} -n ${TEST_NAMESPACE} || true
        fi
    done

    if [[ $completed_jobs -eq 3 ]]; then
        return 0
    else
        log_error "Only $completed_jobs out of 3 jobs completed successfully"
        return 1
    fi
}

# Test 5: Verify lifecycle configurations are applied to MinIO buckets
test_verify_lifecycle_configs() {
    log_info "Verifying lifecycle configurations are applied to MinIO buckets..."

    local buckets=("test-bucket-1" "test-bucket-2" "test-bucket-3")
    local verified_buckets=0

    for bucket in "${buckets[@]}"; do
        log_info "Checking lifecycle configuration for bucket: $bucket"

        # Get current lifecycle configuration from MinIO
        if aws s3api get-bucket-lifecycle-configuration \
            --bucket ${bucket} \
            --endpoint-url ${MINIO_ENDPOINT} > /tmp/${bucket}-lifecycle.json 2>/dev/null; then

            # Verify the configuration contains expected rules
            if jq -e '.Rules[] | select(.Status == "Enabled")' /tmp/${bucket}-lifecycle.json > /dev/null; then
                log_success "Bucket '$bucket' has active lifecycle rules"
                verified_buckets=$((verified_buckets + 1))
            else
                log_error "Bucket '$bucket' lifecycle rules are not enabled"
            fi
        else
            log_error "Could not retrieve lifecycle configuration for bucket '$bucket'"
        fi
    done

    if [[ $verified_buckets -eq 3 ]]; then
        return 0
    else
        log_error "Only $verified_buckets out of 3 buckets have correct lifecycle configurations"
        return 1
    fi
}

# Test 6: Test configuration updates (idempotency)
test_idempotency() {
    log_info "Testing configuration idempotency..."

    # Run the jobs again to verify they detect no changes needed
    local cronjobs=($(kubectl get cronjobs -n ${TEST_NAMESPACE} --no-headers -o custom-columns=":metadata.name"))

    for cronjob in "${cronjobs[@]}"; do
        # Create another manual job
        kubectl create job "${cronjob}-idempotency-$(date +%s)" \
            --from=cronjob/${cronjob} \
            --namespace=${TEST_NAMESPACE}
    done

    # Wait for jobs to complete
    sleep 30

    # Check if jobs completed successfully (should be no-op)
    local idempotent_jobs=($(kubectl get jobs -n ${TEST_NAMESPACE} -l job-name --no-headers -o custom-columns=":metadata.name" | grep idempotency))
    local success_count=0

    for job in "${idempotent_jobs[@]}"; do
        local status=$(kubectl get job ${job} -n ${TEST_NAMESPACE} -o jsonpath='{.status.conditions[0].type}')
        if [[ "$status" == "Complete" ]]; then
            success_count=$((success_count + 1))
        fi
    done

    if [[ $success_count -eq 3 ]]; then
        log_success "All idempotency tests passed"
        return 0
    else
        log_error "Idempotency test failed: $success_count out of 3 jobs succeeded"
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
    run_test "MinIO Connectivity" test_minio_connectivity
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
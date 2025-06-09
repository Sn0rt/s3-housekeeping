#!/bin/bash

# Local E2E Test Script for S3 Housekeeping with MinIO
# This script can be run locally to test the setup before GitHub Actions

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check if minikube is installed
    if ! command -v minikube &> /dev/null; then
        log_error "minikube is not installed. Please install minikube first."
        exit 1
    fi

    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi

    # Check if helm is installed
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed. Please install helm first."
        exit 1
    fi

    # Check if aws is installed
    if ! command -v aws &> /dev/null; then
        log_error "aws CLI is not installed. Please install aws CLI first."
        exit 1
    fi

    log_success "All prerequisites are installed"
}

start_minikube() {
    log_info "Starting minikube..."

    # Check if minikube is already running
    if minikube status | grep -q "host: Running"; then
        log_success "Minikube is already running"
    else
        log_info "Starting minikube cluster..."
        minikube start --memory=4096 --cpus=2
    fi

    # Set kubectl context
    kubectl config use-context minikube
    log_success "Minikube is ready"
}

deploy_minio() {
    log_info "Deploying MinIO..."

    # Create namespace
    kubectl create namespace minio 2>/dev/null || true

    # Deploy MinIO using direct YAML
    kubectl apply -f chart/tests/e2e/minio.yaml -n minio

    # Wait for deployment to be ready
    kubectl wait --for=condition=available deployment/minio -n minio --timeout=300s

    log_success "MinIO deployed successfully"
}

run_e2e_tests() {
    log_info "Running E2E tests..."

    # Make sure the script is executable
    chmod +x chart/tests/e2e/run-e2e-tests.sh

    # Run the e2e tests
    chart/tests/e2e/run-e2e-tests.sh
}

cleanup() {
    log_info "Cleaning up..."
    kubectl delete ns minio s3-housekeeping-e2e --force --grace-period=0 2>/dev/null || true

    log_success "Basic cleanup completed"
}

main() {
    echo "🚀 Local E2E Test Setup for S3 Housekeeping"
    echo "============================================"

    # Handle cleanup on exit
    trap cleanup EXIT

    check_prerequisites
    start_minikube
    deploy_minio
    run_e2e_tests

    log_success "Local E2E test completed successfully!"
}

# Handle command line arguments
case "${1:-}" in
    "cleanup")
        cleanup
        exit 0
        ;;
    "setup")
        check_prerequisites
        start_minikube
        deploy_minio
        log_success "Local E2E test environment setup completed!"
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "Usage: $0 [setup|cleanup]"
        echo "  setup   - Only setup the test environment"
        echo "  cleanup - Only cleanup the test environment"
        echo "  (no args) - Run full e2e test"
        exit 1
        ;;
esac
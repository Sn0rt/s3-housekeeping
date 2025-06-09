# E2E Tests for S3 Housekeeping

This directory contains end-to-end tests for the S3 Housekeeping Helm chart using MinIO as a test S3 service.

## Overview

The E2E tests verify that:
1. The Helm chart deploys correctly
2. CronJobs are created for each S3 bucket
3. Lifecycle configurations are applied to MinIO buckets
4. The system works correctly with different credential configurations
5. Idempotency works (running the same configuration twice doesn't cause issues)

## Test Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   GitHub        │    │   Minikube       │    │   MinIO         │
│   Actions       │───▶│   Cluster        │───▶│   S3 Service    │
│                 │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                                ▼
                       ┌──────────────────┐
                       │ S3 Housekeeping  │
                       │ Helm Chart       │
                       └──────────────────┘
```

## Files

- `run-e2e-tests.sh` - Main E2E test script
- `values-e2e-test.yaml` - Helm values for E2E testing
- `local-test.sh` - Script for running tests locally
- `README.md` - This documentation

## Test Configuration

The E2E tests use the following configuration:

### Test Bucket
- `my-bucket` - Uses standard lifecycle configuration with transitions and expiration rules

### Test Scenarios
1. **Direct MinIO Deployment**: Uses Kubernetes YAML instead of Helm chart
2. **Single Bucket Testing**: Focus on core functionality with one bucket
3. **Lifecycle Configuration**: Tests transition and expiration rules
4. **Debug Mode**: Tests detailed logging capabilities

## Running Tests

### Automated (GitHub Actions)

Tests run automatically on:
- Push to `main` or `develop` branches
- Pull requests to `main` branch
- Manual workflow dispatch

### Local Testing

#### Prerequisites

Make sure you have the following tools installed:
- [minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [aws CLI](https://aws.amazon.com/cli/)

#### Quick Start

```bash
# Run full E2E test
./chart/tests/e2e/local-test.sh

# Only setup the test environment
./chart/tests/e2e/local-test.sh setup

# Only cleanup the test environment
./chart/tests/e2e/local-test.sh cleanup
```

#### Manual Steps

1. **Start minikube**:
   ```bash
   minikube start --memory=4096 --cpus=2
   ```

2. **Deploy MinIO**:
   ```bash
   kubectl create namespace minio
   kubectl apply -f chart/tests/e2e/minio.yaml -n minio
   kubectl wait --for=condition=available deployment/minio -n minio --timeout=300s
   ```

3. **Setup port forwarding**:
   ```bash
   kubectl port-forward -n minio svc/minio 9000:9000 &
   ```

4. **Configure AWS CLI**:
   ```bash
   aws configure set aws_access_key_id admin
   aws configure set aws_secret_access_key password
   aws configure set default.region us-east-1
   ```

5. **Run E2E tests**:
   ```bash
   ./chart/tests/e2e/run-e2e-tests.sh
   ```

## Test Results

The E2E tests provide detailed output including:
- ✅ Successful test steps
- ❌ Failed test steps with error details
- 📊 Summary of passed/failed tests
- 🔍 Detailed logs for debugging failures

### Example Output

```
🚀 Starting S3 Housekeeping E2E Tests
======================================
MinIO Endpoint: http://localhost:9000
Test Namespace: s3-housekeeping-e2e

==========================================
🧪 Running test: MinIO Connectivity
==========================================
ℹ️  Testing MinIO connectivity and bucket creation...
✅ Bucket 'test-bucket-1' exists and is accessible
✅ Bucket 'test-bucket-2' exists and is accessible
✅ Bucket 'test-bucket-3' exists and is accessible
✅ Test 'MinIO Connectivity' passed

==========================================
🏁 E2E Test Summary
==========================================
Total Tests: 6
Passed: 6
Failed: 0

🎉 All E2E tests passed successfully!
The S3 Housekeeping chart is working correctly with MinIO.
```

## Troubleshooting

### Common Issues

1. **MinIO not accessible**:
   - Check if port forwarding is working: `curl http://localhost:9000/minio/health/live`
   - Restart port forwarding: `kubectl port-forward -n minio svc/minio 9000:9000`

2. **Jobs failing to start**:
   - Check pod logs: `kubectl logs -l app.kubernetes.io/name=s3-housekeeping -n s3-housekeeping-e2e`
   - Check events: `kubectl get events -n s3-housekeeping-e2e --sort-by=.metadata.creationTimestamp`

3. **AWS CLI connection issues**:
   - Verify configuration: `aws configure list`
   - Test connection: `aws s3 ls --endpoint-url http://localhost:9000`

4. **Helm chart deployment issues**:
   - Check template rendering: `helm template ./chart --values chart/tests/e2e/values-e2e-test.yaml`
   - Check release status: `helm status s3-housekeeping-e2e -n s3-housekeeping-e2e`

### Debugging

Enable debug mode in the values file:
```yaml
debug: true
```

This provides detailed logging including:
- Configuration details
- AWS CLI commands being executed
- Lifecycle configuration comparisons
- Script execution traces

### Cleanup

For local testing, simple cleanup is sufficient:

```bash
# Stop port forwarding (basic cleanup)
./chart/tests/e2e/local-test.sh cleanup

# Or restart minikube for complete reset
minikube delete && minikube start
```

## Contributing

When adding new test scenarios:

1. Update `values-e2e-test.yaml` with new test configurations
2. Add test functions to `run-e2e-tests.sh`
3. Update this README with the new test scenarios
4. Ensure tests are idempotent and clean up after themselves
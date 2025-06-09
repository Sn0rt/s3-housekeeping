# S3 Housekeeping Helm Chart

This Helm Chart deploys Kubernetes CronJobs to check whether objects in S3 buckets are affected by specified lifecycle rules. Each bucket gets its own dedicated CronJob for better debugging and monitoring.

## Features

- 🔄 **Scheduled Checks**: Use CronJobs to periodically execute S3 lifecycle checks
- 🔐 **Security**: Support for S3 credentials managed through configuration
- 🌐 **Multi-Endpoint Support**: Support for custom S3 endpoints (MinIO, Ceph, etc.)
- 📊 **Detailed Reporting**: Provide detailed check results and statistics
- ♻️ **Reentrant Script**: Safe to run multiple times without side effects
- 🔧 **Highly Configurable**: Flexible configuration through values.yaml
- 🚀 **Independent CronJobs**: Each bucket gets its own CronJob for better isolation and debugging

## Architecture

This chart creates one CronJob per bucket configuration. Each CronJob:
- Has its own S3 credentials
- Can use different S3 endpoints
- Runs independently for better fault isolation
- Uses the same global schedule for consistency

## Environment Variables

Each CronJob supports the following environment variables:

| Variable | Description | Source |
|----------|-------------|--------|
| `S3_BUCKET_NAME` | S3 bucket name | Values (static) |
| `S3_LIFECYCLE_CONFIG_NAME` | Lifecycle rule name | Values (static) |
| `S3_ENDPOINT` | S3 endpoint URL | Values (static) |
| `S3_CA_BUNDLE` | CA certificate bundle path | Values (static) |
| `AWS_ACCESS_KEY_ID` | AWS Access Key ID | Secret (per-bucket) |
| `AWS_SECRET_ACCESS_KEY` | AWS Secret Access Key | Secret (per-bucket) |

### Environment Variable Sources

- **Static variables**: Sourced from values.yaml configuration
- **AWS credentials**: Per-bucket configuration from existing Secrets

## Quick Start

### 1. Configure values.yaml

Create your configuration file:

```yaml
s3:
  buckets:
    - name: "my-production-bucket"
      lifecycleConfigName: "prod-lifecycle"
      accessKeyId:
        secretName: "prod-aws-credentials"
        secretKey: "AWS_ACCESS_KEY_ID"
      secretAccessKey:
        secretName: "prod-aws-credentials"
        secretKey: "AWS_SECRET_ACCESS_KEY"
      endpoint: "https://s3.amazonaws.com"
    - name: "my-archive-bucket"
      lifecycleConfigName: "archive-lifecycle"
      accessKeyId:
        secretName: "minio-credentials"
        secretKey: "access-key"
      secretAccessKey:
        secretName: "minio-credentials"
        secretKey: "secret-key"
      endpoint: "https://minio.example.com"
      caBundle: "/path/to/ca-bundle.pem"

cronJob:
  schedule: "0 2 * * *"  # Run at 2 AM daily
```

### 2. Deploy the Chart

```bash
helm install s3-housekeeping ./s3-housekeeping-chart -f my-values.yaml
```

## Configuration Parameters

### CronJob Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cronJob.schedule` | Cron schedule expression | `"0 * * * *"` |
| `cronJob.concurrencyPolicy` | Concurrency policy | `Forbid` |
| `cronJob.successfulJobsHistoryLimit` | Successful jobs history limit | `3` |
| `cronJob.failedJobsHistoryLimit` | Failed jobs history limit | `1` |
| `cronJob.activeDeadlineSeconds` | Job timeout | `3600` |
| `cronJob.restartPolicy` | Restart policy | `OnFailure` |

### Image Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Container image repository | `amazonlinux` |
| `image.tag` | Image tag | `"2023.4.20240319.1"` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |

### S3 Bucket Configuration

Each bucket in the `s3.buckets` array supports:

| Parameter | Description | Required |
|-----------|-------------|----------|
| `name` | S3 bucket name | ✅ |
| `lifecycleConfigName` | Lifecycle rule name | ✅ |
| `accessKeyId.secretName` | Secret name containing Access Key ID | ✅ |
| `accessKeyId.secretKey` | Key name in Secret for Access Key ID | ✅ |
| `secretAccessKey.secretName` | Secret name containing Secret Access Key | ✅ |
| `secretAccessKey.secretKey` | Key name in Secret for Secret Access Key | ✅ |
| `endpoint` | S3 endpoint URL | ✅ |
| `caBundle` | CA certificate bundle path | ❌ |

## Usage Examples

### Multi-Bucket Configuration

```yaml
s3:
  buckets:
    # AWS S3 bucket
    - name: "aws-production-bucket"
      lifecycleConfigName: "prod-lifecycle"
      accessKeyId:
        secretName: "aws-credentials"
        secretKey: "AWS_ACCESS_KEY_ID"
      secretAccessKey:
        secretName: "aws-credentials"
        secretKey: "AWS_SECRET_ACCESS_KEY"
      endpoint: "https://s3.amazonaws.com"

    # MinIO bucket
    - name: "minio-backup-bucket"
      lifecycleConfigName: "backup-lifecycle"
      accessKeyId:
        secretName: "minio-credentials"
        secretKey: "access-key"
      secretAccessKey:
        secretName: "minio-credentials"
        secretKey: "secret-key"
      endpoint: "https://minio.internal.com"

    # Ceph S3 bucket with custom CA
    - name: "ceph-archive-bucket"
      lifecycleConfigName: "archive-lifecycle"
      accessKeyId:
        secretName: "ceph-credentials"
        secretKey: "ceph_access_key"
      secretAccessKey:
        secretName: "ceph-credentials"
        secretKey: "ceph_secret_key"
      endpoint: "https://ceph-s3.internal.com"
      caBundle: "/etc/ssl/certs/ceph-ca.pem"
```

### Simple Configuration Example

```yaml
s3:
  buckets:
    - name: "production-bucket"
      lifecycleConfigName: "prod-lifecycle"
      accessKeyId:
        secretName: "aws-credentials"
        secretKey: "AWS_ACCESS_KEY_ID"
      secretAccessKey:
        secretName: "aws-credentials"
        secretKey: "AWS_SECRET_ACCESS_KEY"
      endpoint: "https://s3.amazonaws.com"

# Create the credentials manually:
# kubectl create secret generic aws-credentials \
#   --from-literal=AWS_ACCESS_KEY_ID=AKIA... \
#   --from-literal=AWS_SECRET_ACCESS_KEY=...
```

### Multi-Environment Deployment

Create different values files for different environments:

```bash
# Development environment
helm install s3-housekeeping-dev ./s3-housekeeping-chart -f values-dev.yaml

# Production environment
helm install s3-housekeeping-prod ./s3-housekeeping-chart -f values-prod.yaml
```

### View Job Execution Logs

```bash
# View CronJobs
kubectl get cronjobs

# View recent Jobs
kubectl get jobs

# View logs for a specific bucket
kubectl logs -l s3-housekeeping.io/bucket=my-production-bucket

# View logs for all s3-housekeeping jobs
kubectl logs -l app.kubernetes.io/name=s3-housekeeping
```

## Monitoring and Debugging

### Check Individual Bucket Status

Since each bucket has its own CronJob, you can monitor them individually:

```bash
# List all s3-housekeeping CronJobs
kubectl get cronjobs -l app.kubernetes.io/name=s3-housekeeping

# Check specific bucket CronJob
kubectl describe cronjob s3-housekeeping-my-production-bucket

# View logs for specific bucket
kubectl logs -l s3-housekeeping.io/bucket=my-production-bucket
```

### Manual Job Trigger

```bash
# Trigger a specific bucket check manually
kubectl create job --from=cronjob/s3-housekeeping-my-production-bucket manual-check-$(date +%Y%m%d-%H%M%S)
```

## Troubleshooting

### Common Issues

1. **S3 Credentials Error**
   - Check if the credentials in the bucket configuration are correct
   - Verify that the credentials have sufficient S3 permissions

2. **Network Connection Issues**
   - Check if the cluster can access the S3 endpoint
   - Verify firewall and security group configurations
   - For custom endpoints, ensure DNS resolution works

3. **Lifecycle Rule Not Found**
   - Use AWS CLI to check the bucket's lifecycle configuration
   - Ensure the rule name matches exactly with the configuration

4. **CA Certificate Issues**
   - For custom S3 endpoints, ensure the CA bundle path is correct
   - Verify the certificate is properly mounted in the container

### Debug Commands

```bash
# View all CronJobs
kubectl get cronjobs -l app.kubernetes.io/name=s3-housekeeping

# Check CronJob status
kubectl describe cronjob <cronjob-name>

# View ConfigMap content
kubectl get configmap <release-name>-s3-housekeeping-script -o yaml

# Check recent job history
kubectl get jobs -l app.kubernetes.io/name=s3-housekeeping --sort-by=.metadata.creationTimestamp
```

## Generated Resources

This chart creates the following Kubernetes resources:

- **ConfigMap**: Contains the lifecycle check scripts
- **CronJob** (one per bucket): Individual CronJobs for each bucket

Note: This chart does not create Secrets for AWS credentials. You must create them manually with the names and keys specified in your bucket configurations.

Example generated CronJob names:
- `release-name-s3-housekeeping-my-production-bucket`
- `release-name-s3-housekeeping-my-archive-bucket`

## Uninstall

```bash
helm uninstall s3-housekeeping
```

This will remove all CronJobs and ConfigMaps created by the chart.

## Contributing

Welcome to submit Issues and Pull Requests to improve this chart.

## License

MIT License
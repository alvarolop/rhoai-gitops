# Data Connection Configuration for RHOAI 3.4+

## Overview

This directory contains templates for creating data connections (S3-compatible storage) that are properly recognized by the OpenShift AI dashboard and can be associated with model servers.

## Important: Updated Annotations (RHOAI 3.4)

Starting with RHOAI 3.0, the connection annotation format has changed:

- ❌ **Deprecated**: `opendatahub.io/connection-type: s3`
- ✅ **Current**: `opendatahub.io/connection-type-protocol: "s3"`

The new `opendatahub.io/connection-type-protocol` annotation takes precedence and enables protocol-based validation.

## Connection Secret Structure

### Required Labels
```yaml
labels:
  opendatahub.io/dashboard: 'true'    # Makes connection visible in dashboard
  opendatahub.io/managed: 'true'      # Marks as managed by OpenShift AI
```

### Required Annotations
```yaml
annotations:
  opendatahub.io/connection-type-protocol: "s3"  # Protocol type
  openshift.io/display-name: "My Connection"     # Display name in UI
```

### Required Data Fields (S3)
```yaml
stringData:
  AWS_ACCESS_KEY_ID: "..."
  AWS_SECRET_ACCESS_KEY: "..."
  AWS_S3_ENDPOINT: "https://..."
  AWS_S3_BUCKET: "bucket-name"
  AWS_DEFAULT_REGION: "us-east-1"  # Optional
```

## Using Connections with InferenceService

When deploying models with KServe/ModelMesh, reference the connection in your InferenceService:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-model
  annotations:
    # Reference the connection secret
    opendatahub.io/connections: 'my-s3-connection'
    # Optional: Specify path within bucket
    opendatahub.io/connection-path: 'models/my-model/v1'
    # Deployment mode
    serving.kserve.io/deploymentMode: ModelMesh
spec:
  predictor:
    model:
      modelFormat:
        name: pytorch
      storage:
        key: my-s3-connection  # Reference to secret name
        path: models/my-model/v1
```

## Connection Path Annotation

The `opendatahub.io/connection-path` annotation is **optional but highly recommended**:
- Specifies the exact folder path within the S3 bucket
- Helps the dashboard show which models use which connections
- Makes it easier to track model-to-connection relationships

## Supported Connection Types

| Protocol | Annotation Value | Use Case |
|----------|-----------------|----------|
| S3-compatible | `s3` | Object storage (AWS S3, MinIO, ODF) |
| URI-based | `uri` | Generic URI connections |
| OCI Registry | `oci` | Container registries |

## Cross-namespace Access

⚠️ **Important**: Connections can only be used by resources within the same namespace. Cross-namespace access is not supported.

## GitOps Best Practices

For production deployments:
- Use **SealedSecrets** or **ExternalSecrets** instead of storing base64-encoded secrets in Git
- Never commit actual credentials to version control
- Use the OpenShift Template format (as in this directory) with parameters

## References

- [RHOAI 3.4 Working on Projects](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/working_on_projects/)
- [Connection API Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4)

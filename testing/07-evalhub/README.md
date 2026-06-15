# EvalHub Testing Notebooks

This directory contains Jupyter notebooks for testing and demonstrating the EvalHub evaluation service in Red Hat OpenShift AI (RHOAI).

## Overview

EvalHub is a service for evaluating LLM models using standardized benchmarks and evaluation frameworks. These notebooks demonstrate how to:
- Create evaluation jobs programmatically via the REST API
- Monitor evaluation job status (running, pending, completed, failed)
- Authenticate to models using API tokens
- Troubleshoot common issues

## Prerequisites

### Infrastructure
- RHOAI 3.4+ installed with EvalHub enabled
- At least one LLM model deployed (e.g., `tinyllama-1b` in `models-as-a-service` namespace)
- MLflow enabled for experiment tracking

### Permissions
Users creating evaluation jobs need MLflow RBAC permissions. The GitOps chart includes a RoleBinding:
```yaml
# See: rhoai-installation-chart/templates/13-mlflow/RoleBinding-evalhub-mlflow-user-access.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: evalhub-mlflow-user-access
  namespace: models-as-a-service
roleRef:
  kind: ClusterRole
  name: trustyai-service-operator-evalhub-mlflow-access
subjects:
  - kind: Group
    name: rhods-admins  # RHOAI administrators
```

### Python Dependencies
```bash
pip install requests urllib3
```

### Environment Setup

**When running in RHOAI Workbench (Recommended):**
The notebooks automatically detect the workbench environment and retrieve:
- ✅ OpenShift token from `/var/run/secrets/kubernetes.io/serviceaccount/token`
- ✅ Cluster domain from OpenShift routes (`oc get route`)
- ✅ Model API token using `oc get secret` commands

**No manual configuration needed!** Just upload the notebooks to your workbench and run the cells.

**When running outside RHOAI (local Jupyter):**
Export your OpenShift authentication token:
```bash
export OPENSHIFT_TOKEN=$(oc whoami -t)
```

Optionally set the cluster domain:
```bash
export CLUSTER_DOMAIN="ocp.sandbox5548.opentlc.com"
```

The model API token is automatically retrieved using `oc` commands if `oc` CLI is available.

## Notebooks

### 1. Create Evaluation (`01-create-evaluation.ipynb`)

Creates an evaluation job for the "Arc Easy" benchmark on the TinyLlama model.

**Features:**
- 🔍 Auto-detect RHOAI workbench environment (token, cluster domain, namespace)
- 🔌 Configure EvalHub endpoint and authentication automatically
- 📋 List available evaluation providers (lm-evaluation-harness, garak, guidellm)
- 📚 List available evaluation collections (safety-and-fairness-v1, etc.)
- 🚀 Create an evaluation job with model authentication
- 💾 Save job ID for later monitoring

**Auto-Detection:**
The notebook automatically retrieves:
- OpenShift token from ServiceAccount (when running in workbench)
- Cluster domain by querying OpenShift routes
- Model API token from Kubernetes secrets

**Example Usage:**
```python
evaluation_job = {
    "name": "EvalHub Eval 01",
    "tenant": "models-as-a-service",
    "model": {
        "name": "tinyllama-1b",
        "url": "https://maas.apps.ocp.sandbox5548.opentlc.com/models-as-a-service/tinyllama-1b",
        "api_key": MODEL_API_TOKEN
    },
    "evaluation": "Arc Easy",
    "provider": "lm-evaluation-harness",
    "limit": 10
}
```

### 2. Check Evaluations (`02-check-evaluations.ipynb`)

Monitors and displays the status of evaluation jobs.

**Features:**
- List all evaluation jobs in a namespace
- Get detailed status of a specific job
- Filter jobs by status (running, pending, completed, failed)
- Poll a job until completion with progress updates
- Check underlying Kubernetes Job and Pod resources
- View MLflow experiment results

**Status Categories:**
- **⟳ Running**: Job is actively executing
- **⏸ Pending**: Job is waiting to start (queued or pod not ready)
- **✓ Completed**: Job finished successfully with results
- **✗ Failed**: Job encountered an error

## EvalHub API Endpoints

The notebooks use the following EvalHub REST API endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/v1/health` | GET | Health check |
| `/api/v1/evaluations/providers` | GET | List available evaluation providers |
| `/api/v1/evaluations/collections` | GET | List available evaluation collections |
| `/api/v1/evaluations/jobs` | GET | List evaluation jobs (filter by tenant) |
| `/api/v1/evaluations/jobs` | POST | Create new evaluation job |
| `/api/v1/evaluations/jobs/{id}` | GET | Get specific job details |

## Troubleshooting

### 1. 403 Forbidden - MLflow Permissions

**Symptom:**
```json
{"message_code":"mlflow_request_failed","message":"Permission denied for requested operation."}
```

**Cause:** User doesn't have MLflow RBAC permissions in the tenant namespace.

**Fix:**
```bash
# Verify RoleBinding exists
kubectl get rolebinding evalhub-mlflow-user-access -n models-as-a-service

# Check if you're in the rhods-admins group
oc get groups rhods-admins
```

### 2. 401 Unauthorized - Authentication

**Symptom:**
```json
{"message_code":"unauthorized","message":"The request is not authenticated."}
```

**Fix:**
```bash
# Get fresh OpenShift token
export OPENSHIFT_TOKEN=$(oc whoami -t)
```

### 3. Job Stuck in Pending

**Symptom:** Evaluation job shows "Pending" status for extended period.

**Debug:**
```bash
# List Jobs
kubectl get jobs -n models-as-a-service

# Check Pod status
kubectl get pods -n models-as-a-service | grep eval

# Describe pod for events
kubectl describe pod <pod-name> -n models-as-a-service
```

**Common causes:**
- Pod waiting for Kueue admission
- Init container stuck mounting volumes
- Secret not found (see Known Issues below)

### 4. Job Failed

**Debug:**
```bash
# Get pod logs
kubectl logs <pod-name> -n models-as-a-service

# Check Job events
kubectl describe job <job-name> -n models-as-a-service
```

## Known Issues (RHOAI 3.4.0)

### Model Authentication Token Bug

**Issue:** EvalHub incorrectly uses the model API key **token value** (JWT string) as a Kubernetes secret name instead of creating a proper secret reference.

**Symptoms:**
- Job pods stuck in `Init:0/1` status
- Error: `MountVolume.SetUp failed for volume "model-auth" : secret "eyJhbGci..." not found`
- Secret name is a 1000+ character JWT instead of a DNS-compliant name

**Root Cause:**
When creating an evaluation via the dashboard, the UI passes the API key token **value** to EvalHub. EvalHub then generates a Job spec with:
```yaml
volumes:
  - name: model-auth
    secret:
      secretName: eyJhbGciOiJSUzI1NiIsImtpZCI6IllGdFBrYzQ4...  # ❌ Invalid - this is the token VALUE
```

Instead of:
```yaml
volumes:
  - name: model-auth
    secret:
      secretName: tinyllama-1b-sa-token  # ✅ Correct - this is the secret NAME
```

**Impact:** Evaluation jobs **cannot run** against MaaS models with authentication enabled.

**Workarounds:**
1. **Report to Red Hat Support**: This is a product bug that should be fixed
2. **Test without auth**: Deploy a model without `security.opendatahub.io/enable-auth` for testing
3. **Wait for fix**: Track RHOAI 3.5 or upcoming 3.4.x patches

**Related Issues:**
- EvalHub uses end-user credentials for MLflow API calls (not evalhub-service ServiceAccount)
- This design means each user needs MLflow RBAC permissions, not just the service

## Example Workflow

### From RHOAI Workbench (Recommended)

```bash
# 1. Create a workbench in RHOAI dashboard
#    - Name: evalhub-testing
#    - Image: Standard Data Science
#    - Container size: Small

# 2. Upload notebooks
#    - Upload 01-create-evaluation.ipynb
#    - Upload 02-check-evaluations.ipynb

# 3. Run notebooks in order
#    - All configuration auto-detected!
#    - No environment variables needed
#    - Just execute cells sequentially

# 4. Monitor from terminal (optional)
oc get jobs -n models-as-a-service -w
oc get pods -n models-as-a-service -w
```

### From Local Jupyter

```bash
# 1. Set up environment (optional - auto-detected if oc CLI available)
export OPENSHIFT_TOKEN=$(oc whoami -t)
export CLUSTER_DOMAIN="ocp.sandbox5548.opentlc.com"

# 2. Start JupyterLab
jupyter lab

# 3. Run notebooks in order
# - 01-create-evaluation.ipynb
# - 02-check-evaluations.ipynb
```

## MLflow Integration

Evaluation results are stored in MLflow experiments:

- **MLflow Dashboard**: `https://mlflow-redhat-ods-applications.apps.ocp.sandbox5548.opentlc.com`
- **Experiment naming**: Jobs create experiments in the tenant namespace
- **Results**: Metrics, parameters, and artifacts from evaluation runs

## References

- [RHOAI 3.4 Evaluating AI Systems Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/evaluating_ai_systems/)
- [EvalHub GitOps Configuration](../../rhoai-installation-chart/templates/12-evalhub/)
- [MLflow RBAC Configuration](../../rhoai-installation-chart/templates/13-mlflow/)
- [TrustyAI Operator Documentation](https://access.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed/3.4/html/evaluating_ai_systems/configuring-trustyai-operator_evaluating-ai-systems)

## Architecture

```
┌─────────────┐     REST API      ┌──────────────┐
│  Notebook   │ ─────────────────> │   EvalHub    │
│   (User)    │  Bearer Token      │   Service    │
└─────────────┘                    └──────┬───────┘
                                          │
                     ┌────────────────────┼────────────────────┐
                     │                    │                    │
                     v                    v                    v
              ┌──────────────┐    ┌─────────────┐     ┌─────────────┐
              │  Kubernetes  │    │   MLflow    │     │    Model    │
              │     Job      │───>│  Tracking   │     │  Inference  │
              │              │    │   Server    │     │   Service   │
              └──────────────┘    └─────────────┘     └─────────────┘
                     │                                        ^
                     │                                        │
                     └────────── HTTP Request ────────────────┘
                              (with model API token)
```

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review pod logs and events
3. Consult RHOAI documentation
4. Open a Red Hat support case for product bugs

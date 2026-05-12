# NVIDIA MIG Configuration for RHOAI

This directory contains HardwareProfile configurations for NVIDIA H100 94GB GPUs with Multi-Instance GPU (MIG) support.

## Overview

NVIDIA MIG technology allows partitioning a single GPU into multiple independent instances, enabling better resource utilization and multi-tenancy. For H100 94GB GPUs, we provide three MIG profiles.

## MIG Strategy

This configuration uses the **"mixed" strategy**, which exposes each MIG profile as a distinct resource type:
- `nvidia.com/mig-1g.12gb`
- `nvidia.com/mig-3g.47gb`
- `nvidia.com/mig-7g.94gb`

## Available HardwareProfiles

### 1. MIG 1g.12gb (Small Instance)
- **Resource**: `nvidia.com/mig-1g.12gb`
- **Memory**: ~12GB per instance
- **Instances per GPU**: 7
- **Use Cases**: Inference workloads, small models, development/testing
- **CPU Range**: 1-4 cores
- **Memory Range**: 1-16 GiB

**File**: `HardwareProfile-mig-1g-12gb.yaml`

### 2. MIG 3g.47gb (Medium Instance)
- **Resource**: `nvidia.com/mig-3g.47gb`
- **Memory**: ~47GB per instance
- **Instances per GPU**: 2
- **Use Cases**: Medium-sized models, fine-tuning, batch inference
- **CPU Range**: 1-8 cores
- **Memory Range**: 1-32 GiB

**File**: `HardwareProfile-mig-3g-47gb.yaml`

### 3. MIG 7g.94gb (Full GPU)
- **Resource**: `nvidia.com/mig-7g.94gb`
- **Memory**: 94GB (full GPU)
- **Instances per GPU**: 1
- **Use Cases**: Large models, training, multi-GPU inference
- **CPU Range**: 1-16 cores
- **Memory Range**: 1-64 GiB

**File**: `HardwareProfile-mig-7g-94gb.yaml`

## Prerequisites

### 1. NVIDIA GPU Operator Configuration

Your cluster must have the NVIDIA GPU Operator configured with MIG support in "mixed" mode:

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
spec:
  mig:
    strategy: mixed
```

### 2. Node Labeling

Nodes with H100 GPUs must be labeled with the appropriate MIG configuration:

```bash
# Example: Configure node with specific MIG profile
oc label node <node-name> nvidia.com/mig.config=all-1g.12gb --overwrite

# Or use a custom configuration
oc label node <node-name> nvidia.com/mig.config=custom-config --overwrite
```

### 3. Verify MIG Configuration

Check that MIG instances are properly exposed:

```bash
# Check node capacity
oc describe node <node-name> | grep -A 5 "Capacity:"

# You should see entries like:
# nvidia.com/mig-1g.12gb: 7
# nvidia.com/mig-3g.47gb: 2
# nvidia.com/mig-7g.94gb: 1
```

## ClusterQueue Configuration

The ClusterQueue in `06-kueue/clusterqueue-cluster-queue.yaml` defines quotas for each MIG profile:

```yaml
resourceGroups:
  # MIG 1g.12gb - Small instances
  - coveredResources: ["cpu", "memory", "nvidia.com/mig-1g.12gb"]
    flavors:
      - name: "mig-1g-12gb"
        resources:
          - name: "nvidia.com/mig-1g.12gb"
            nominalQuota: "14"  # 2 GPUs × 7 instances
  
  # MIG 3g.47gb - Medium instances
  - coveredResources: ["cpu", "memory", "nvidia.com/mig-3g.47gb"]
    flavors:
      - name: "mig-3g-47gb"
        resources:
          - name: "nvidia.com/mig-3g.47gb"
            nominalQuota: "4"  # 2 GPUs × 2 instances
  
  # MIG 7g.94gb - Full GPU instances
  - coveredResources: ["cpu", "memory", "nvidia.com/mig-7g.94gb"]
    flavors:
      - name: "mig-7g-94gb"
        resources:
          - name: "nvidia.com/mig-7g.94gb"
            nominalQuota: "2"  # 2 full GPUs
```

Adjust the `nominalQuota` values based on your cluster's actual GPU count and desired allocation.

## Using MIG Profiles in RHOAI

### In Workbenches

Users can select the appropriate MIG profile when creating a workbench:
1. Create a new workbench
2. In the hardware profile section, choose:
   - "H100 MIG 1g.12gb" for small workloads
   - "H100 MIG 3g.47gb" for medium workloads
   - "H100 MIG 7g.94gb" for full GPU access

### In PyTorchJobs/Distributed Workloads

Example PyTorchJob requesting a MIG instance:

```yaml
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: training-job-mig
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      template:
        spec:
          containers:
          - name: pytorch
            image: pytorch/pytorch:latest
            resources:
              limits:
                nvidia.com/mig-3g.47gb: 1  # Request MIG 3g.47gb instance
                cpu: "4"
                memory: "16Gi"
```

### In Model Serving (KServe/vLLM)

Example InferenceService with MIG:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llm-inference
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
      resources:
        limits:
          nvidia.com/mig-1g.12gb: 1  # Small MIG for inference
          cpu: "2"
          memory: "8Gi"
```

## Troubleshooting

### MIG instances not appearing

1. **Check GPU Operator status**:
   ```bash
   oc get pods -n nvidia-gpu-operator
   ```

2. **Verify MIG configuration**:
   ```bash
   # On the GPU node
   nvidia-smi mig -lgi  # List GPU instances
   ```

3. **Check node labels**:
   ```bash
   oc get node <node-name> --show-labels | grep mig
   ```

### Pods stuck in Pending

1. **Check ResourceFlavor tolerations** in `06-kueue/resourceflavor-mig-*.yaml`
2. **Verify ClusterQueue quotas** are not exhausted
3. **Check node taints** match the ResourceFlavor tolerations

### HardwareProfile not showing in dashboard

1. **Verify namespace**: HardwareProfiles must be in `redhat-ods-applications`
2. **Check annotations**: Ensure `opendatahub.io/disabled: 'false'`
3. **Restart dashboard**: `oc delete pod -n redhat-ods-applications -l app=rhods-dashboard`

## References

- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)
- [MIG Support in OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/mig-ocp.html)
- [How MIG maximizes GPU efficiency on OpenShift AI](https://developers.redhat.com/articles/2025/02/06/how-mig-maximizes-gpu-efficiency-openshift-ai)
- [RHOAI Distributed Workloads Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-distributed-workloads_managing-rhoai)
- [Kueue ResourceFlavor Documentation](https://kueue.sigs.k8s.io/docs/concepts/resource_flavor/)

## Example MIG Configurations

For H100 94GB, common MIG configurations include:

| Configuration Name | Profile | Instances | Memory/Instance |
|-------------------|---------|-----------|-----------------|
| all-1g.12gb | 1g.12gb | 7 | ~12GB |
| all-3g.47gb | 3g.47gb | 2 | ~47GB |
| all-7g.94gb | 7g.94gb | 1 | 94GB |
| mixed-1g-3g | 1g.12gb × 1<br>3g.47gb × 2 | 3 total | Mixed |

You can create custom configurations by editing the MIG configuration ConfigMap.

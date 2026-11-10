# NVIDIA MIG Configuration for RHOAI

Reference configuration for NVIDIA H100 94GB GPUs with Multi-Instance GPU (MIG) support.

> [!NOTE]
> **Not deployed by default.** The chart targets AWS `g6` nodes (1x NVIDIA L4, which does not support MIG): one `gpu-flavor`
> with a plain `nvidia.com/gpu` quota. The MIG configuration is kept as **commented blocks at the end of the same files**
> as the default one (marked `Reference: NVIDIA H100 with MIG`). See [Enabling MIG](#enabling-mig).

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

**Defined (commented) in**: `templates/07-hardware-profiles/HardwareProfile-gpu-profile.yaml` (`mig-1g-12gb-profile`)

### 2. MIG 3g.47gb (Medium Instance)
- **Resource**: `nvidia.com/mig-3g.47gb`
- **Memory**: ~47GB per instance
- **Instances per GPU**: 2
- **Use Cases**: Medium-sized models, fine-tuning, batch inference
- **CPU Range**: 1-8 cores
- **Memory Range**: 1-32 GiB

**Defined (commented) in**: `templates/07-hardware-profiles/HardwareProfile-gpu-profile.yaml` (`mig-3g-47gb-profile`)

### 3. MIG 7g.94gb (Full GPU)
- **Resource**: `nvidia.com/mig-7g.94gb`
- **Memory**: 94GB (full GPU)
- **Instances per GPU**: 1
- **Use Cases**: Large models, training, multi-GPU inference
- **CPU Range**: 1-16 cores
- **Memory Range**: 1-64 GiB

**Defined (commented) in**: `templates/07-hardware-profiles/HardwareProfile-gpu-profile.yaml` (`mig-7g-94gb-profile`)

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

## Enabling MIG

Uncomment (remove the leading `# `) the block marked `Reference: NVIDIA H100 with MIG` at the end of each of these files:

| File (in `templates/`) | What to uncomment |
|---|---|
| `06-kueue/resourceflavor-gpu-flavor.yaml` | the three MIG ResourceFlavors |
| `06-kueue/clusterqueue-serving.yaml` | the replacement `resourceGroups` (replace the active one) |
| `06-kueue/clusterqueue-batch.yaml` | the replacement `resourceGroups` (replace the active one) |
| `07-hardware-profiles/HardwareProfile-gpu-profile.yaml` | the three MIG HardwareProfiles |

A resource name can only be covered by **one** `resourceGroup` per ClusterQueue, so do not add one group per MIG profile
(Kueue rejects it with `Duplicate value: "cpu"`). The replacement block keeps a single group, adds the MIG resources to
`coveredResources` and one flavor per MIG profile, and every flavor lists all covered resources **in the same order**,
with quota `0` for the ones it does not provide. The quotas in the examples are for 2 H100 GPUs: adjust them to your
cluster. Because `serving-cq` owns all the MIG slices, `batch-cq` borrows them and is evicted when a model needs them
back, exactly like the plain GPU pool.

## Using MIG Profiles in RHOAI

### In Workbenches

> [!WARNING]
> RHOAI only lets workbenches use a **non-preemptive** queue, because workbenches cannot be suspended. The MIG
> profiles point at `serving-lq` (or `batch-lq`), whose queues can preempt workloads, so use them for model serving and
> batch work, not for workbenches.

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

1. **Check ResourceFlavor tolerations** in `06-kueue/resourceflavor-gpu-flavor.yaml`
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

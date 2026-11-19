# Dynamic Resource Allocation (DRA) for GPUs

How the GPU gets from the card to the model pod with DRA, what this repo installs and why it differs from the classic device plugin. Verified on OpenShift 4.22 (Kubernetes 1.35, `resource.k8s.io/v1`, GPU Operator 26.7.3).

## 1. The idea in one picture

DRA is a layer between the hardware and the pods. The hardware **publishes** what it has, the admin **names classes** of devices, and the pod **claims** by attributes instead of by count.

```
 HARDWARE                 PUBLISHES               CLASSES                 CLAIMS                  CONSUMER
┌────────────┐      ┌────────────────┐     ┌────────────────┐     ┌──────────────────┐     ┌─────────────┐
│ GPU node   │      │ ResourceSlice  │     │ DeviceClass    │     │ ResourceClaim    │     │ Pod         │
│  L4  /     │ ───▶ │ one entry per  │ ──▶ │ gpu.nvidia.com │ ──▶ │ (from a          │ ──▶ │ vLLM of the │
│  H100+MIG  │      │ device, with   │     │ mig.nvidia.com │     │ ResourceClaim-   │     │ model       │
│            │      │ attributes     │     │ (made by NVIDIA)│    │ Template, CEL)   │     │             │
└────────────┘      └────────────────┘     └────────────────┘     └──────────────────┘     └─────────────┘
 DRA driver           DRA driver             DRA driver             this chart (06-dra)      this chart (demo)
```

Who makes each piece:

| Object | Created by | Scope |
|---|---|---|
| `ResourceSlice` | The NVIDIA DRA driver (kubelet plugin on each GPU node) | cluster |
| `DeviceClass` (`gpu.nvidia.com`, `mig.nvidia.com`, `vfio.gpu.nvidia.com`) | The NVIDIA GPU Operator, together with the DRA driver. Not this repo | cluster |
| `ResourceClaimTemplate` | This chart, `templates/06-dra` | namespace |
| `ResourceClaim` | Kubernetes, one per pod, from the template | namespace |

## 2. Device plugin versus DRA

```
 CLASSIC (device plugin)                          DRA
 ───────────────────────                          ───
 node advertises:  nvidia.com/gpu: 1              node publishes: device "gpu-0"
                                                    productName = NVIDIA L4
                                                    memory      = 24Gi
                                                    profile     = (MIG only, e.g. 2g.20gb)

 pod asks:                                        pod asks:
   resources:                                       resourceClaims:
     limits:                                          - name: gpu
       nvidia.com/gpu: 1                                resourceClaimTemplateName: gpu-l4
                                                    ...claim says: deviceClass + CEL selector
 You get "a GPU", a count.                        You get "a device that matches", with alternatives.
```

| | Device plugin (`device-plugin/`) | DRA (`dra/`) |
|---|---|---|
| Operator CR | `ClusterPolicy` | `GPUCluster` + `NVIDIADriver` |
| Request | `nvidia.com/gpu` limit | `ResourceClaim` with CEL on attributes |
| MIG partitioning | MIG manager (node label) | preconfigured MIG, or `DynamicMIG` (alpha) creates it at allocation |
| Alternatives | none | `firstAvailable` (ordered list) |
| Both in one cluster | No: `GPUCluster` and `ClusterPolicy` exclude each other, and there is no in-place migration | |

## 3. What this repo installs

```
rhoai-dependencies/operator-nvidia-gpu/
├── operator/        Namespace, OperatorGroup, Subscription (channel v26.7)   shared
├── dashboard/       DCGM exporter dashboard for the console                   shared
├── device-plugin/   ClusterPolicy                                             classic flavor
└── dra/             GPUCluster + NVIDIADriver                                 DRA flavor (default)

rhoai-installation-chart/templates/
└── 06-dra/                       ResourceClaimTemplates (full GPU; H100 MIG, off)
```

`variants/default` points to `operator-nvidia-gpu/dra`. To go back, change that line to `operator-nvidia-gpu/device-plugin`, delete the `GPUCluster`, and set `dra.enabled: false` in the chart values.

## 4. How a model uses the claim

`gpu-l4` asks for one full GPU of the product in `dra.gpu.productName`:

```yaml
kind: ResourceClaimTemplate
spec:
  spec:
    devices:
      requests:
        - name: gpu
          exactly:
            deviceClassName: gpu.nvidia.com
            selectors:
              - cel:
                  expression: device.attributes['gpu.nvidia.com'].productName == "NVIDIA L4"
```

The models are deployed from the `rhoai-serving` repository. A model refers to the template in its pod template; there is no `nvidia.com/gpu` limit:

```yaml
template:
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: gpu-l4
  containers:
    - name: main
      resources:
        claims:
          - name: gpu
```

The scheduler allocates a device from a `ResourceSlice` that matches the CEL expression, and the kubelet plugin gives it to the container (through CDI).

## 5. H100 with MIG, prepared but off

`dra.mig` in `values.yaml` renders a template with a prioritized list. The scheduler tries the alternatives in order:

```
 claim "mig-h100"
   │
   ├─ 1) preferred : 1 × mig.nvidia.com with profile 2g.20gb      ← tried first
   │        └─ no such device left?
   └─ 2) fallback  : 2 × mig.nvidia.com with profile 1g.10gb      ← used only if (1) cannot be satisfied
```

To use it, enable `dra.mig.enabled` and the `DynamicMIG` feature gate in `dra/GPUCluster.yaml` (alpha: the driver creates the MIG device when the claim is allocated). Without `DynamicMIG` only full GPUs and MIG devices that already exist can be allocated, and the `GPUCluster` flavor has no MIG manager to create them.

Caveat: one vLLM process only sees the first MIG device of its list, so the 2-partition fallback does not spread one model across partitions. It fits several single-partition replicas or a bigger profile.

## 6. What changes for the rest of the platform

- **Hardware profiles.** The GPU `HardwareProfile`s of `05-hardware-profiles` use the `nvidia.com/gpu` identifier. There is no device plugin in the DRA flavor, so they do not match DRA devices. RHOAI 3.5.3 has no DRA field in `HardwareProfile` (open upstream pull requests only), so the claims are written by hand in the `LLMInferenceService`.
- **Kueue.** Red Hat build of Kueue 1.5 counts DRA device quota only on OpenShift 5.0 and later. On 4.22 the `nvidia.com/gpu` quota in the ClusterQueues does not account for DRA claims.
- **Metrics.** The `GPUCluster` runs its own DCGM exporter (`nvidia-dcgm-exporter-dra`) with a ServiceMonitor, so GPU metrics keep flowing.

## 7. Commands to look at it

```bash
oc get gpucluster,nvidiadriver                 # operator CRs
oc get deviceclass                             # made by NVIDIA
oc get resourceslice                           # devices published by the node
oc get resourceslice -o yaml | grep -A12 attributes   # productName, memory, profile...
oc get resourceclaimtemplate -A                # what this chart creates
oc get resourceclaim -A                        # one per running pod, with its allocation
```

## 8. References

- [Dynamic resource allocation goes GA in Red Hat OpenShift 4.21](https://developers.redhat.com/articles/2026/03/25/dynamic-resource-allocation-goes-ga-red-hat-openshift-421-smarter-gpu) (includes a `firstAvailable` MIG example)
- [Multitenant AI inference with dynamic resource allocation on OpenShift](https://developers.redhat.com/articles/2026/08/03/multitenant-ai-inference-dynamic-resource-allocation-openshift) (H100 MIG slices with llm-d)
- [DRA Driver for NVIDIA GPUs, GPU Operator docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/dra-intro-install.html)
- [NVIDIA cloud-native-docs PR 518: GPU Operator with DRA on OpenShift](https://github.com/NVIDIA/cloud-native-docs/pull/518)

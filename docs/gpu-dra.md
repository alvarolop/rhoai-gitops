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
       nvidia.com/gpu: 1                                resourceClaimTemplateName: gpu-m-x1
                                                    ...claim says: deviceClass + CEL selector
 You get "a GPU", a count.                        You get "a device that matches".
```

| | Device plugin (`device-plugin/`) | DRA (`dra/`) |
|---|---|---|
| Operator CR | `ClusterPolicy` | `GPUCluster` + `NVIDIADriver` |
| Request | `nvidia.com/gpu` limit | `ResourceClaim` with CEL on attributes |
| MIG partitioning | MIG manager (node label) | preconfigured MIG, or `DynamicMIG` (alpha) creates it at allocation |
| Alternatives | none | `firstAvailable` (ordered list; not used here: Kueue does not support it) |
| Both in one cluster | No: `GPUCluster` and `ClusterPolicy` exclude each other, and there is no in-place migration | |

## 3. What this repo installs

```
rhoai-dependencies/operator-nvidia-gpu/
├── operator/        Namespace, OperatorGroup, Subscription (channel v26.7)   shared
├── dashboard/       DCGM exporter dashboard for the console                   shared
├── device-plugin/   ClusterPolicy                                             classic flavor (default)
└── dra/             GPUCluster + NVIDIADriver                                 DRA flavor

rhoai-installation-chart/templates/
└── 06-dra/                       ResourceClaimTemplates: t-shirt sizes gpu-<size>-x<count>
```

DRA is off by default (Kueue does not support it for all we need): `variants/*` point to `operator-nvidia-gpu/device-plugin` and the chart has `dra.enabled: false`. To use DRA, change that line to `operator-nvidia-gpu/dra`, delete the `ClusterPolicy` and set `dra.enabled: true` in the chart values.

## 4. T-shirt sizes of GPU

The platform defines sizes; a model asks for a size, not for hardware. The same definitions then fit different clusters. Each size is its own file in `templates/06-dra` (`ResourceClaimTemplate-gpu-<size>-x<count>.yaml`, hardcoded, not a loop over `values.yaml`); `x<count>` is the number of GPUs, as in AWS instance types:

| Template | Request (one exact device request with a CEL selector on memory) |
|---|---|
| `gpu-s-x1` | 1 full GPU with 16 Gi or more |
| `gpu-m-x1` | 1 full GPU with 22 Gi or more (the L4 reports 23034 Mi) |
| `gpu-l-x1` | 1 full GPU with 78 Gi or more (H100 80GB reports 79.6 Gi) |
| `gpu-xl-x1` | 1 full GPU with 140 Gi or more (B200, H200); fits Llama 70B in BF16 |
| `gpu-xl-x2` | 2 full GPUs with 78 Gi or more each (2 × H100 80GB or 94GB, H200, B200); Llama 70B in BF16 (tight on 2 × 80GB: limit the context); needs `parallelism.tensor: 2` |

**No `firstAvailable`.** Kueue cannot admit a workload whose claim uses it (`FirstAvailable device selection is not supported`): the pod stays `SchedulingGated` and the Workload `Inadmissible`. So each size is one `exactly` request and the same definition fits different clusters only by memory. Without it one request cannot offer both a full GPU and a MIG partition. A small model on a big card takes the whole card.

The alternatives (MIG partitions first, then the full GPU by memory) are kept as a commented `firstAvailable` reference at the end of each `x1` file, for when Kueue supports it (`KueueDRAIntegrationPrioritizedList` gate, alpha). They need MIG devices (the `DynamicMIG` feature gate in `dra/GPUCluster.yaml`, alpha, or partitions already created) and are untested here.

Where each size lands:

| Cluster | `gpu-s-x1` | `gpu-m-x1` | `gpu-l-x1` | `gpu-xl-x1` | `gpu-xl-x2` |
|---|---|---|---|---|---|
| L4 only (this one, 23034 Mi) | the L4 | the L4 | does not schedule | does not schedule | does not schedule |
| H100 | whole H100 | whole H100 | whole H100 | does not schedule | 2 whole H100 (needs 2 on the node) |
| B200 / H200 | whole GPU | whole GPU | whole GPU | whole GPU | 2 whole GPUs |

More GPUs (`gpu-xl-x2` is the example; `gpu-xl-x4`) need `parallelism.tensor` in the model; a commented reference sits at the end of `ResourceClaimTemplate-gpu-l-x1.yaml`.

The models are deployed from the `rhoai-serving` repository. A model names the template in its pod template; there is no `nvidia.com/gpu` limit:

```yaml
template:
  resourceClaims:
    - name: gpu
      resourceClaimTemplateName: gpu-m-x1
  containers:
    - name: main
      resources:
        claims:
          - name: gpu
```

The scheduler allocates a device from a `ResourceSlice` that matches the CEL expression of the request, and the kubelet plugin gives it to the container (through CDI). The request name of the allocated `ResourceClaim` is `gpu`.

## 5. One HardwareProfile for all sizes

The size is chosen by the claim template, so the `HardwareProfile` does not need to know about it. `gpu-dra-profile` has only CPU and memory identifiers and the queue `serving-lq`; every size works with it. It has no `nvidia.com/gpu` identifier on purpose: the RHOAI webhook would add that limit on top of the claim and Kueue would count 2 GPUs against a quota of 1 (the pod stays `SchedulingGated`). RHOAI 3.5.3 has no DRA field in `HardwareProfile` (open upstream pull requests only); when it exists, a profile per size could point to its template.

## 6. What changes for the rest of the platform

- **Hardware profiles.** `gpu-profile` and `gpu-batch-profile` use the `nvidia.com/gpu` identifier and do not match DRA devices (there is no device plugin). Use `gpu-dra-profile` (serving, queue `serving-lq`) or `gpu-dra-batch-profile` (batch, spot queue `batch-lq`).
- **Kueue.** Red Hat build of Kueue 1.5 evaluates the claims. It needs the DeviceClasses mapped to a resource name (`04-kueue/Kueue.yaml` maps `gpu.nvidia.com` and `mig.nvidia.com` to `nvidia.com/gpu`), so a claim counts against the same quota as a `nvidia.com/gpu` limit and a MIG partition counts as one unit. Quota in consumable capacity (GPU memory) needs OpenShift 5.0.
- **Metrics.** The `GPUCluster` runs its own DCGM exporter (`nvidia-dcgm-exporter-dra`) with a ServiceMonitor, so GPU metrics keep flowing.
- **Node taint.** The GPU nodes carry `nvidia.com/gpu:NoSchedule`; the `GPUCluster` tolerates it for its daemonsets, and `gpu-flavor` of Kueue adds the toleration to the pods.

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

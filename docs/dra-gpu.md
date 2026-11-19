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
└── 06-dra/                       ResourceClaimTemplates: t-shirt sizes gpu-<size>-x<count>
```

`variants/default` points to `operator-nvidia-gpu/dra`. To go back, change that line to `operator-nvidia-gpu/device-plugin`, delete the `GPUCluster`, and set `dra.enabled: false` in the chart values.

## 4. T-shirt sizes of GPU

The platform defines sizes; a model asks for a size, not for hardware. The same definitions then fit different clusters. Each size is its own file in `templates/06-dra` (`ResourceClaimTemplate-gpu-<size>-x<count>.yaml`, hardcoded, not a loop over `values.yaml`); `x<count>` is the number of GPUs, as in AWS instance types:

| Template | Alternatives, in order (first one that fits wins) |
|---|---|
| `gpu-s-x1` | MIG `1g.12gb` → MIG `2g.24gb` → any full GPU with 16 Gi or more |
| `gpu-m-x1` | full L4 → MIG `2g.24gb` (about 1/4 of an H100) → any full GPU with 22 Gi or more |
| `gpu-l-x1` | full GPU with 80 Gi or more (H100) → MIG `7g.94gb` (the whole H100 in MIG mode) |

```
 model asks for gpu-m-x1
   │
   ├─ 1) full GPU, productName "NVIDIA L4"            ← L4 cluster: lands here
   ├─ 2) 1 × mig.nvidia.com, profile 2g.24gb          ← H100 94GB cluster: lands here
   └─ 3) full GPU with 22 Gi or more                  ← anything else that is big enough
```

Where each size lands:

| Cluster | `gpu-s-x1` | `gpu-m-x1` | `gpu-l-x1` |
|---|---|---|---|
| L4 only (this one, 23034 Mi) | the L4 (last alternative) | the L4 | does not schedule |
| H100 94GB with MIG | MIG `1g.12gb` | MIG `2g.24gb` | whole H100 |

All the alternatives of a size give the same number of devices, so with `x1` the tensor parallelism of the model stays 1. More GPUs (`gpu-xl-x4`) need `parallelism.tensor` in the model and the same count in every alternative; a commented reference sits at the end of `ResourceClaimTemplate-gpu-l-x1.yaml`.

MIG alternatives need MIG devices: the `DynamicMIG` feature gate in `dra/GPUCluster.yaml` (alpha, the driver creates the partition when the claim is allocated) or partitions that already exist. The `GPUCluster` flavor has no MIG manager. The MIG alternatives and the H100 profiles are untested here: this cluster only has an L4.

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

The scheduler allocates a device from a `ResourceSlice` that matches the CEL expression of the first alternative that fits, and the kubelet plugin gives it to the container (through CDI). The chosen alternative is the `request` field of the allocated `ResourceClaim` (for example `gpu/gpu-nvidia-l4`).

## 5. One HardwareProfile for all sizes

The size is chosen by the claim template, so the `HardwareProfile` does not need to know about it. `gpu-dra-profile` has only CPU and memory identifiers and the queue `serving-lq`; every size works with it. It has no `nvidia.com/gpu` identifier on purpose: the RHOAI webhook would add that limit on top of the claim and Kueue would count 2 GPUs against a quota of 1 (the pod stays `SchedulingGated`). RHOAI 3.5.3 has no DRA field in `HardwareProfile` (open upstream pull requests only); when it exists, a profile per size could point to its template.

## 6. What changes for the rest of the platform

- **Hardware profiles.** `gpu-profile` and `gpu-batch-profile` use the `nvidia.com/gpu` identifier and do not match DRA devices (there is no device plugin). Use `gpu-dra-profile`.
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

# Monitoring models at every level

What to watch when you serve models with OpenShift AI 3.5, where each signal lives, and how to read it. It covers four levels, from the user who calls the model down to the GPU and its cost:

1. [Models-as-a-Service (MaaS): who consumes what](#1-models-as-a-service-who-consumes-what)
2. [vLLM and llm-d: how the models behave](#2-vllm-and-llm-d-how-the-models-behave)
3. [GPUs: consumption, capacity and cost](#3-gpus-consumption-capacity-and-cost)
4. [Where the data lives today](#4-where-the-data-lives-today) (the inventory of sources that a unified strategy has to merge)

Conventions used in this page:

- **Observed** means I checked it on a live cluster of this repo (OCP 4.22, RHOAI 3.5.3, one NVIDIA L4 on `g6.2xlarge`). **Docs** means it comes from the RHOAI 3.5 documentation. **To validate** means the query is built from metric names and labels that exist, but it has not been run against real traffic.
- PromQL examples use the raw vLLM names (`vllm:...`). In the RHOAI platform stack the same metrics carry the prefix `kserve_vllm:` (see [section 4](#4-where-the-data-lives-today)).

## The path of a request

```
client ──► MaaS gateway ──► Authorino ──► Limitador ──► llm-d gateway/EPP ──► vLLM pod ──► GPU
 (API key)  (Envoy/Istio)   (who are you)  (token quota)  (picks the replica)   (the engine)   (DCGM)
```

Each hop has its own metrics, and a problem shows up at a different level depending on where it starts:

| Symptom the user reports | Look first at |
|---|---|
| `401` / `403` | Level 1: Authorino, subscriptions and authorization policies |
| `429` | Level 1: Limitador, the token quota of the subscription |
| Slow first token | Level 2: queue time and prefill time, the KV cache, the EPP routing |
| Slow stream (tokens come out one by one) | Level 2: inter-token latency, batch size, GPU saturation |
| `5xx` or timeouts | Level 2: gateway status codes, vLLM health; level 3: GPU errors |
| "The model is down" | Level 2: ready pods and endpoints; level 3: node and GPU health, Kueue admission |
| The invoice is too high | Level 3: allocated GPU-hours, idle time, tokens per hour |

---

## 1. Models-as-a-Service: who consumes what

MaaS adds governance in front of the models: a subscription says how many tokens a group can use per time window, an authorization policy says who can reach a model, and every user calls with an API key bound to one subscription. The questions at this level are about **consumption, fairness and access**.

### What to look at

| Question | Signal | Source |
|---|---|---|
| How many tokens did each subscription, user or model consume? | `authorized_hits` (tokens counted against the limit) | Limitador |
| How many requests? | `authorized_calls` | Limitador |
| Who is being rate limited, and how often? | `limited_calls` (requests rejected with `429`) | Limitador |
| Is the quota well sized? | rate-limit ratio = `limited_calls / (authorized_calls + limited_calls)` | derived |
| Is authentication healthy and fast? | `auth_server_authconfig_duration_seconds_*`, `auth_server_authconfig_response_status` | Authorino |
| Are the policies being enforced? | `kuadrant_policies_enforced`, `kuadrant_allowed`, `kuadrant_denied`, `kuadrant_errors`, `kuadrant_hits`, `kuadrant_misses` | Kuadrant (in the gateway pods) |
| Is the gateway healthy and how fast is it? | `istio_requests_total` by `response_code`, `istio_request_duration_milliseconds_*` | Envoy / Istio |
| Is the control plane up? | `limitador_up`, `kube_pod_status_phase` of `maas-api`, `authorino`, the gateway pods | Limitador, kube-state-metrics |
| Are API keys working? | `maas-api` and `maas-controller` metrics (PodMonitors `maas-api-metrics`, `maas-controller-metrics`) and the PostgreSQL behind them | maas-api |

**Labels that matter.** The usage counters carry `user`, `subscription` and `model`. Which dimensions exist is controlled by `MaasTenantConfig.spec.telemetry` (docs):

| Setting | Effect | Value in this repo |
|---|---|---|
| `telemetry.enabled` | turns telemetry on or off | `true` |
| `metrics.captureModelUsage` | adds the `model` dimension | `true` |
| `metrics.captureOrganization` | adds `organization` | `true` |
| `metrics.captureUser` | adds `user` (the authenticated user id; **privacy implications**) | `true` |
| `metrics.captureGroup` | adds `group` | `false` |

Turning `captureUser` off removes the per-user view (the "AI engineer" dashboard depends on it) but keeps subscription and model views. Decide it per audience: for a demo `true` is convenient; for a customer with privacy rules it is a conversation to have.

### Useful queries (to validate with traffic)

```promql
# Tokens consumed in the last 24 h, per subscription and model
sum by (subscription, model) (increase(authorized_hits[24h]))

# Requests in the last 24 h
sum by (subscription, model) (increase(authorized_calls[24h]))

# Top 10 users by tokens
topk(10, sum by (user) (increase(authorized_hits[24h])))

# Rate-limit ratio per subscription (the share of requests that got a 429)
sum by (subscription) (rate(limited_calls[5m]))
  / (sum by (subscription) (rate(authorized_calls[5m])) + sum by (subscription) (rate(limited_calls[5m])))

# Authorization latency p95 (Authorino)
histogram_quantile(0.95, sum by (le) (rate(auth_server_authconfig_duration_seconds_bucket[5m])))

# Gateway errors and latency per backend service
sum by (destination_service_name) (rate(istio_requests_total{response_code=~"5.."}[5m]))
histogram_quantile(0.95, sum by (le, destination_service_name) (rate(istio_request_duration_milliseconds_bucket[5m])))
```

### How to read it

- **A subscription at 100 % of its quota** (`limited_calls` rising) is either undersized or being abused. Compare it with the number of distinct users: one heavy user against a shared limit is a different problem from everybody hitting it.
- **Tokens count prompt and completion together.** Clients such as Open WebUI send extra requests per message (title, tags, follow-ups), so the consumption can be several times what the person typed. This is why the `tinyllama-1b` limit in this repo is generous.
- **`403` with a valid key** usually means a subscription without an authorization policy; **`429` on the first request** means the opposite (policy without subscription). Both resources are required for each model.
- **Keys:** temporary keys last 1 hour, others can be permanent or expire. Revocations and expirations are an operational signal, not a metric: track them through the `maas-api` logs and the API.

### Where to see it

- **RHOAI dashboard → Observe & monitor → Usage** (Technology Preview): tokens, requests and rate-limit violations per subscription and user, with **CSV export** for showback.
- **Grafana dashboards of this repo** (`10-maas/4-grafana`): *MaaS AI Engineer* (one user's usage, trends, hourly patterns) and *MaaS Platform Admin* (component health, auth evaluation and latency, gateway, token and request totals per model/subscription, alerts).
- **Observed on this cluster:** the usage counters (`authorized_*`, `limited_calls`) and the Authorino `auth_server_*` series **do not exist yet** because no request has gone through MaaS. Counters appear after the first evaluation, so the dashboards stay empty until you send traffic. Only `limitador_up` and the `kuadrant_*` series (all at 0) are there.

### What to alert on

| Alert | Why |
|---|---|
| `limitador_up == 0`, Authorino or `maas-api` pods not running, gateway pods not running | MaaS is down or cannot enforce quotas |
| `kuadrant_errors` or `5xx` from the gateway above a baseline | the policy path is failing |
| Rate-limit ratio above a threshold for a subscription | quota too tight or a runaway client |
| Authorization p95 above ~100 ms | auth is becoming the bottleneck |
| MaaS reported `Degraded` | user workload monitoring is missing (docs: MaaS needs it) |

---

## 2. vLLM and llm-d: how the models behave

This level answers: **is the model fast, saturated or wasting capacity?** There are two sources. The **vLLM engine** reports what happens inside each replica. The **llm-d endpoint picker (EPP)**, also called the inference scheduler, reports how requests are routed across replicas. On OpenShift the controller creates the scrape configuration for both when you deploy an `LLMInferenceService` (docs): a `PodMonitor` (`kserve-llm-isvc-vllm-engine`) for the engines on port 8000 and a `ServiceMonitor` (`kserve-llm-isvc-scheduler`) for the EPP. Both were **observed** in `models-as-a-service`. They need **user workload monitoring** to be scraped (docs).

### 2.1 vLLM engine metrics

Labels on every series (observed): `model_name`, `llm_isvc_name`, `llm_isvc_role` (`both`, `prefill` or `decode`), `llm_isvc_component`, `namespace`, `pod`.

**Saturation: is it full?**

| Metric | Meaning | How to read it |
|---|---|---|
| `vllm:num_requests_running` | requests being decoded now | the batch in flight; compare with the configured max |
| `vllm:num_requests_waiting` | requests queued | **the earliest saturation signal**: it rises before latency does. Sustained `> 0` means you need more replicas or a bigger batch |
| `vllm:num_requests_waiting_by_reason` | why they wait | capacity versus deferral, useful to tell memory pressure from scheduling |
| `vllm:kv_cache_usage_perc` | share of the KV cache in use (0–1) | above ~0.9 requests start waiting or get preempted. The key capacity metric: GPU memory use is not (see section 3) |
| `vllm:num_preemptions_total` | requests evicted from the batch and recomputed | any steady rate means the KV cache is too small for the traffic: latency spikes and wasted compute |

**Latency: what does the user feel?** (all are histograms, use `histogram_quantile`)

| Metric | Meaning | Typical use |
|---|---|---|
| `vllm:time_to_first_token_seconds` (TTFT) | time until the first token | responsiveness. Driven by queue time and prefill. The metric that degrades first under load |
| `vllm:inter_token_latency_seconds` (ITL) | time between tokens | streaming speed. Driven by batch size and GPU saturation |
| `vllm:e2e_request_latency_seconds` | whole request | the SLO most people quote |
| `vllm:request_queue_time_seconds` | waiting in the queue | if TTFT is high and this is high, it is capacity; if this is low, it is prefill (long prompts) |
| `vllm:request_prefill_time_seconds`, `vllm:request_decode_time_seconds` | phases of a request | where the time goes: long prompts show in prefill, long answers in decode |

**Throughput and demand**

| Metric | Meaning |
|---|---|
| `vllm:prompt_tokens_total`, `vllm:generation_tokens_total` | tokens processed and generated; their rates are the throughput and the basis of the cost per token |
| `vllm:request_success_total` | finished requests by `finished_reason` (`stop`, `length`, `abort`...). A rising share of `length` means answers are being cut; `abort` means clients are leaving |
| `vllm:request_prompt_tokens`, `vllm:request_generation_tokens` | distribution of prompt and answer sizes: the workload shape |
| `vllm:iteration_tokens_total` | tokens per engine step: how well the batch is filled |

**Cache efficiency**

| Metric | Meaning |
|---|---|
| `vllm:prefix_cache_hits_total`, `vllm:prefix_cache_queries_total` | prefix-cache hit ratio. High is good: repeated system prompts and chat history are not recomputed. Routing that is aware of the cache (see the EPP) raises it |
| `vllm:prompt_tokens_cached_total`, `vllm:external_prefix_cache_*` | cached prompt tokens and hits on external/offloaded cache |

**Newer or specialised series** present on this cluster: `vllm:estimated_flops_per_gpu_total` and `vllm:estimated_{read,write}_bytes_per_gpu_total` (estimated compute and memory traffic per GPU, a way to see whether the model is compute- or bandwidth-bound), `vllm:engine_sleep_state`, `vllm:cache_config_info` (static: cache size and block size), and for disaggregated prefill/decode the `vllm:nixl_*` family (KV transfer time, bytes, failures).

**Queries (to validate with traffic)**

```promql
# TTFT, inter-token and end-to-end latency, p95 per model
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:time_to_first_token_seconds_bucket[5m])))
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:inter_token_latency_seconds_bucket[5m])))
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:e2e_request_latency_seconds_bucket[5m])))

# Throughput in tokens per second
sum by (model_name) (rate(vllm:generation_tokens_total[5m]))
sum by (model_name) (rate(vllm:prompt_tokens_total[5m]))

# Saturation
sum by (model_name) (vllm:num_requests_waiting)
max by (model_name, pod) (vllm:kv_cache_usage_perc)
sum by (model_name) (rate(vllm:num_preemptions_total[5m]))

# Prefix-cache hit ratio
sum by (model_name) (rate(vllm:prefix_cache_hits_total[5m]))
  / sum by (model_name) (rate(vllm:prefix_cache_queries_total[5m]))

# Why requests end
sum by (finished_reason) (rate(vllm:request_success_total[5m]))
```

### 2.2 llm-d endpoint picker (EPP) and gateway

The EPP chooses which replica gets each request, using queue depth, KV cache use and prefix-cache locality. Its metrics tell you whether routing is healthy and whether it is actually helping.

| Group | Metrics (docs and observed) | What it answers |
|---|---|---|
| Pool health | `inference_pool_ready_pods`, `llm_d_epp_ready_endpoints`, `inference_pool_average_kv_cache_utilization`, `inference_pool_average_queue_size` | how many replicas are ready and how loaded the pool is on average |
| Routing decisions | `inference_objective_request_total`, `inference_objective_request_error_total`, `llm_d_inference_scheduler_disagg_decision_total` | how many requests were routed, how many failed, and (with prefill/decode disaggregation) how often the split was used |
| Routing cost | `inference_extension_scheduler_e2e_duration_seconds`, `inference_extension_plugin_duration_seconds`, `llm_d_epp_prefix_indexer_size` | how long choosing a replica takes and how big the prefix index is |
| Service-level request metrics | series with the `llm_d_epp_` prefix: TTFT, TPOT, ITL, error rate and duration as the user perceives them | user-perceived latency: it includes the wait in the scheduler and the network, so it is **higher than the vLLM numbers** and is the right basis for an SLO |

Two things to know about names:

- **The EPP metrics are being renamed.** The cluster exposes both `inference_extension_*` / `inference_pool_*` and the new `llm_d_epp_*` (`llm_d_epp_info`, `llm_d_epp_ready_endpoints`, `llm_d_epp_prefix_indexer_size`). The llm-d Grafana dashboards of this repo use the old `inference_*` names. **Worth checking when real traffic flows** that those panels still return data.
- **The gateway also counts.** The Envoy pods of the llm-d and MaaS gateways are scraped through the `istio-pod-monitor` and the `*-metrics` PodMonitors in `openshift-ingress`; `istio_requests_total` gives request volume and status codes per backend service (observed: it already carries the MLflow and dashboard traffic).

### 2.3 How to read the two together

| What you see | Likely cause | Action |
|---|---|---|
| TTFT up, queue time up, `num_requests_waiting > 0`, KV cache high | the replicas are saturated | add replicas or a bigger GPU; check the EPP spreads load evenly (per-pod request distribution) |
| TTFT up, queue time low | long prompts (prefill-bound) | consider prefill/decode disaggregation, a faster prefill path, or prompt-size limits |
| ITL up, queue low | decode-bound or the batch is too big | reduce concurrency per replica or use a faster GPU |
| Preemptions climbing | KV cache too small for the traffic | lower max model length or concurrency, or more memory per replica |
| One pod much busier than the others | routing is not balancing | look at the EPP decisions, readiness and the prefix-cache hit ratio per pod |
| EPP ready endpoints lower than replicas | replicas not ready or excluded | pod readiness, model loading time, the gang-scheduling timeout of Kueue |
| EPP latency (`llm_d_epp_*`) much higher than vLLM latency | time lost in the scheduler or network | scheduler plugin duration; gateway latency |
| Cache hit ratio near 0 with chat workloads | routing is not cache-aware, or prompts differ | check the EPP scoring configuration |

### 2.4 Where to see it

- **RHOAI dashboard → Observe & monitor** (needs the Cluster Observability Operator and the `metrics` section of `DSCInitialization.spec.monitoring`): *Models* (per deployment: requests, P90 end-to-end latency, error rate, GPU use, queue length, TTFT, token throughput, success rate), *LLM Traffic* (request, error and token rates), *LLM Performance* (TTFT percentiles, ITL, KV cache hit rate) and *LLM Utilization* (per-replica GPU, memory and queue depth). They read from the **RHOAI platform Prometheus**, not from the cluster one.
- **Grafana dashboards of this repo** (`09-llm-d/grafana`): vLLM overview, diagnostic drill-down (KV cache, queues, request distribution, routing decision latency, prefix caching), failure and saturation (errors, preemptions, TTFT and ITL p99, scheduler health), performance and KV cache (per-pod views, EPP pool health) and the prefill/decode coordinator (including NIXL transfers).
- **OpenShift console → Observe → Metrics** for ad-hoc queries over the cluster Prometheus.
- **Observed today:** only the simulator is serving, so the vLLM series are the small subset it emits (requests running and waiting, KV cache usage, cache config). The full engine, latency and EPP picture appears when a real model such as `gpt-oss-20b` receives traffic.

### 2.5 What to alert on

| Alert | Why |
|---|---|
| `num_requests_waiting > 0` for 5 min | saturation |
| `kv_cache_usage_perc > 0.9` for 10 min, or preemption rate above 0 | memory pressure |
| TTFT p95 or ITL p95 above the SLO | user-visible slowness |
| Error ratio of `inference_objective_request_error_total` or gateway `5xx` above baseline | failing requests |
| Ready pods below desired replicas | capacity loss (also check Kueue admission and the node) |

---

## 3. GPUs: consumption, capacity and cost

Three different questions, with three different data sources:

- **Consumption:** how hard are the cards working? (DCGM)
- **Capacity and allocation:** who owns the GPUs and who is waiting? (kube-state-metrics, Kueue, the scheduler)
- **Cost:** what does it cost, and what does a token cost? (derived: there is no native cost metric)

### 3.1 Consumption: DCGM

The NVIDIA GPU Operator runs the DCGM exporter (`ServiceMonitor` `nvidia-dcgm-exporter`, `serviceMonitor.enabled: true` in the `ClusterPolicy`). It is scraped by the cluster Prometheus because the operator namespace carries `openshift.io/cluster-monitoring: 'true'`, so it does not need user workload monitoring. Labels (observed): `hostname`, `gpu`, `UUID`, `modelName` (for example `NVIDIA L4`), `device`, `pci_bus_id`, `DCGM_FI_DRIVER_VERSION`. Note that `pod` and `namespace` are those of the **exporter**, not of the workload using the GPU (see 3.2).

| Metric | Meaning | How to read it |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | percentage of time any kernel was running | coarse. 100 % can still be inefficient, and low values on an inference GPU are normal between bursts |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | graphics engine and tensor cores really active | **better indicators of useful work** than the plain utilization |
| `DCGM_FI_PROF_DRAM_ACTIVE` | memory bandwidth in use | LLM decoding is usually memory-bound: high here with low tensor activity is expected |
| `DCGM_FI_DEV_FB_USED`, `FB_FREE`, `FB_RESERVED` | framebuffer (memory) in MiB | **not a demand signal**: vLLM pre-allocates most of the memory (`gpu-memory-utilization`), so it looks full from the start. Use `vllm:kv_cache_usage_perc` for real pressure |
| `DCGM_FI_DEV_POWER_USAGE` (W) | instantaneous power | proxy for load and for energy cost |
| `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | cumulative energy (mJ) | the basis for kWh and carbon |
| `DCGM_FI_DEV_GPU_TEMP`, `MEMORY_TEMP`, `SM_CLOCK`, `MEM_CLOCK` | thermal and clock state | throttling shows as clocks dropping when the temperature climbs |
| `DCGM_FI_PROF_PCIE_{RX,TX}_BYTES`, `DCGM_FI_DEV_MEM_COPY_UTIL` | data movement | transfer bottlenecks (model loading, multi-GPU) |
| `DCGM_FI_DEV_*REMAPPED_ROWS`, `ROW_REMAP_FAILURE`, `PCIE_REPLAY_COUNTER` | hardware health | any increase deserves attention; a remap failure means replacing the card |

RHOAI also publishes simplified recording series, `accelerator_gpu_utilization`, `accelerator_memory_used_bytes`, `accelerator_power_usage_watts` and `accelerator_temperature_celsius`. They come from the DCGM ones and feed the *Cluster* and *Models* dashboards of the platform; they exist in both Prometheus stacks.

The operator itself exposes health: `gpu_operator_node_driver_ready`, `gpu_operator_node_device_plugin_devices_total`, `gpu_operator_gpu_nodes_total`, `gpu_operator_reconciliation_status` and the driver-toolkit flags. Check those first when a GPU node is up but no pod can use the card.

```promql
# Utilization and real tensor activity per card
DCGM_FI_DEV_GPU_UTIL
avg by (hostname, gpu) (DCGM_FI_PROF_PIPE_TENSOR_ACTIVE)

# Memory occupancy (MiB used / total)
DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)

# Power and energy (cumulative counter in mJ -> kWh per day: 1 kWh = 3.6e9 mJ)
DCGM_FI_DEV_POWER_USAGE
sum by (hostname) (increase(DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION[1d])) / 3.6e9
```

### 3.2 Capacity and allocation: who owns the GPUs

DCGM tells you how a card behaves, not who is using it. For that:

- **Allocation per workload:** `kube_pod_container_resource_requests{resource="nvidia_com_gpu"}` (observed) gives the GPUs requested per pod and namespace. Join it with the pod phase and the node to know which workload owns which card:

```promql
# GPUs held by running pods, per namespace
sum by (namespace) (
  kube_pod_container_resource_requests{resource="nvidia_com_gpu"}
  * on (namespace, pod) group_left () (kube_pod_status_phase{phase="Running"} == 1)
)

# Total GPUs in the cluster
sum(kube_node_status_allocatable{resource="nvidia_com_gpu"})
```

- **Link a card to a workload.** With one GPU per pod you can match by node: the DCGM `hostname` equals the pod's node. With GPU sharing (time slicing or MIG) the match is per card or slice and needs the exporter's pod mapping; I did not find those workload labels on the series of this cluster, so **validate it before relying on per-pod GPU numbers**.
- **Quota and queueing (Kueue).** The reserved-spot design makes this a key view. Metrics (observed): `kueue_cluster_queue_resource_usage` against `kueue_cluster_queue_nominal_quota` (use versus quota, per `cluster_queue`, `flavor` and `resource`), `kueue_cluster_queue_borrowing_limit`, `kueue_pending_workloads` and `kueue_local_queue_pending_workloads` (who is waiting), `kueue_admission_wait_time_seconds` (how long), `kueue_evicted_workloads_total` (batch work preempted to give GPU back to serving).
- **Pending pods:** `scheduler_pending_pods` and the pod events tell apart "no free GPU" from "no quota".

```promql
# GPUs used by the serving and batch queues against their quota
sum by (cluster_queue) (kueue_cluster_queue_resource_usage{resource="nvidia.com/gpu"})
sum by (cluster_queue) (kueue_cluster_queue_nominal_quota{resource="nvidia.com/gpu"})

# Workloads waiting and evictions
sum by (cluster_queue) (kueue_pending_workloads)
sum by (cluster_queue) (increase(kueue_evicted_workloads_total[1d]))
```

### 3.3 Cost

No component exports a cost metric. You derive it from three things you do have: **how many GPU-hours are held**, **what a GPU-hour costs**, and **how many tokens that GPU served**. Do not treat the numbers below as billing: they are an allocation model.

1. **Price of a GPU-hour.** Take the on-demand (or reserved) price of the instance type and region from your cloud pricing (here `g6.2xlarge` in `eu-central-1`, one L4 per node). The instance type is available as a label (`kube_node_labels{label_beta_kubernetes_io_instance_type="g6.2xlarge"}`, observed), so a price table keyed by instance type can be joined in. On multi-GPU instances divide by the number of GPUs.
2. **Allocated cost.** Charge what is **held**, not what is used. A GPU reserved by a model that sits idle still costs the same.
3. **Efficiency.** Compare what is held with what is used to find waste.

```promql
# GPU-hours held per namespace in the last day (multiply by the price per GPU-hour)
sum by (namespace) (
  avg_over_time(kube_pod_container_resource_requests{resource="nvidia_com_gpu"}[1d])
) * 24

# Cost of the last day, with a price per GPU-hour defined as a constant, e.g. 1.0
sum by (namespace) (
  avg_over_time(kube_pod_container_resource_requests{resource="nvidia_com_gpu"}[1d])
) * 24 * 1.0

# Cost per million generated tokens (price per GPU-hour / million tokens per hour)
1.0 / (sum(rate(vllm:generation_tokens_total[1h])) * 3600 / 1e6)

# Idle share: how much of the held GPU time had no kernels running
1 - avg(DCGM_FI_DEV_GPU_UTIL) / 100
```

Ways to turn this into something an engagement can use:

- **Cost per model:** GPU-hours held by the model's namespace or `llm_isvc_name` times the price. Add the share of idle time as "unused capacity".
- **Cost per token:** the formula above, per model. It improves with batching and cache hits, so it moves with the workload, not only with the hardware.
- **Cost per subscription or user (chargeback):** split a model's cost by each subscription's share of its tokens: `authorized_hits` for the subscription divided by the model's total. This is the bridge between levels 1 and 3, and the reason both need to live in the same place.
- **Energy and carbon:** `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` converted to kWh, times a grid factor.
- **Tools to evaluate** instead of building everything: OpenCost or Kubecost (they can consume DCGM and node prices) and Red Hat cost management for the OpenShift side. I have not tested them against GPU workloads on this stack, so treat them as candidates.

### 3.4 What to alert on

| Alert | Why |
|---|---|
| GPU node `NotReady` or `SchedulingDisabled`; `gpu_operator_node_driver_ready == 0`; devices total below expected | the capacity is gone |
| Remapped rows or PCIe replay counter increasing; temperature high with clocks dropping | hardware health and throttling |
| Held GPUs with sustained utilization near 0 for hours | paying for idle cards (candidate to scale to zero or move to batch) |
| `kueue_pending_workloads` above 0 for a long time or frequent evictions | the quota is too small or the queues are mis-sized |
| Cost per day or cost per million tokens above a budget | cost drift |

---

## 4. Where the data lives today

This is the inventory a unified view has to merge. Observed on the cluster of this repo:

| # | Source | What it stores | Who reads it | How it is fed |
|---|---|---|---|---|
| A | **OpenShift monitoring + user workload monitoring** (`thanos-querier` in `openshift-monitoring`) | Everything scraped from the cluster and from user namespaces: DCGM and GPU Operator, kube-state-metrics, Kueue, Kuadrant and the Istio gateways, llm-d EPP, the vLLM engines (both `vllm:` and `kserve_vllm:`), `istio_requests_total` (about 3,900 metric names) | OpenShift console → Observe, the Grafana of this repo (datasource `prometheus-grafana`) | `ServiceMonitor` and `PodMonitor` objects; user workload monitoring is on (`INSTALL_MONITORING`) |
| B | **RHOAI platform stack** (`data-science-monitoringstack` and `data-science-thanos-querier` in `redhat-ods-monitoring`, plus Perses) | A curated subset (about 850 names): `kserve_vllm:` (16 metric names), raw `vllm:`, `istio_*`, the four `accelerator_*` series, `limitador_up` | The RHOAI dashboard → Observe & monitor (Cluster, Models, Usage, LLM Traffic/Performance/Utilization) | OpenTelemetry collector with a target allocator; workloads opt in through the label `monitoring.opendatahub.io/scrape=true` or are picked up by the monitors it ships; it can export to other systems through `DSCInitialization.spec.monitoring.metrics.exporters` |
| C | **Tempo** (`tempo-data-science-tempomonolithic` in `redhat-ods-monitoring` and `openshift-tempo`) | Traces (retention 90 days in this repo, sampling 0.1) | Grafana (datasource `tempo`), Perses | OTLP into the collector (`data-science-collector`, ports 4317 and 4318) |
| D | **Grafana of this repo** (`INSTALL_GRAFANA`) | Nothing of its own: dashboards over A and C (5 llm-d and 2 MaaS dashboards from this chart, plus the ones the RHCL overlay can add) | people | Grafana operator, `GrafanaDashboard` objects |
| E | **Console plugin of the NVIDIA GPU Operator** | The GPU view of the OpenShift console (Cluster overview) | admins | DCGM through A |
| F | **MLflow and EvalHub** | Experiment runs, traces of generative AI apps, evaluation results | data scientists and evaluators | their own APIs |

Facts that explain why it feels fragmented:

- **The same metric exists twice with different names.** vLLM appears as `vllm:*` and as `kserve_vllm:*`. The RHOAI dashboards use the latter; the Grafana dashboards of this repo use the former.
- **MaaS consumption is not in B.** The usage counters come from Limitador, and in B only `limitador_up` is present. The RHOAI *Usage* dashboard and our Grafana dashboards therefore do not necessarily read the same store; confirm it when MaaS has traffic.
- **The GPU dashboards of the platform show utilization, not cost.** Nothing in A or B computes cost or cost per token.
- **User workload monitoring is a prerequisite for several things** (llm-d scraping, MaaS usage), while the platform stack B needs the Cluster Observability, Tempo and OpenTelemetry operators.

### Questions for the unified strategy (to decide)

1. **One store or one pane?** Either feed everything into one Prometheus (B can export to other systems with `metrics.exporters`; A can be queried with its own Thanos), or keep both and put one dashboard layer on top that queries both.
2. **Which dashboard layer is the home?** The RHOAI native one (Perses, in the product, supported, but a fixed set of views) or Grafana (flexible, and the only place today where MaaS governance and cost could be joined).
3. **Which naming do we standardise on** (`vllm:` or `kserve_vllm:`) and what to do with the renamed EPP metrics.
4. **Where does cost live?** A set of recording rules over the formulas of section 3.3, or an external tool (OpenCost, Kubecost, Red Hat cost management).
5. **Privacy and retention:** per-user labels (`captureUser`) and how long to keep per-user consumption.
6. **Alerting:** one Alertmanager (A or B) and a single routing, instead of alerts on both.

## References

- RHOAI 3.5, *Managing OpenShift AI*, chapter *Manage observability* (the observability stack, dashboards, `monitoring.opendatahub.io/scrape`, exporters, built-in alerts).
- RHOAI 3.5, *Deploy models using Distributed Inference with llm-d*, chapter *Monitor llm-d deployments* (metric families, `PodMonitor` and `ServiceMonitor`, built-in dashboards).
- RHOAI 3.5, *Govern LLM access with Models-as-a-Service* (subscriptions, authorization policies, the usage dashboard, `MaasTenantConfig` telemetry).
- NVIDIA DCGM exporter field reference, for the exact meaning of each `DCGM_FI_*` field.
- In this repo: `README.md` (section *Metrics and user-workload monitoring*), `rhoai-installation-chart/templates/10-maas/3-observability` (DSCInitialization and `MaasTenantConfig`), the dashboards under `rhoai-installation-chart/files/`.

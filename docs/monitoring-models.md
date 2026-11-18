# Monitoring models at every level

How the industry frames the monitoring of LLMs, what people actually watch at each level, and how much of it you already get with OpenShift AI 3.5. It is organised in this order:

1. [How the problem is framed](#1-how-the-problem-is-framed): the layers, the signals and the habits that most teams converge on.
2. [Layer by layer: what to watch and where it lives in this stack](#2-layer-by-layer-what-to-watch-and-where-it-lives-in-this-stack): gateway and MaaS, serving (vLLM and llm-d), GPUs, cost, and the application layer.
3. [Coverage: what we have and what is missing](#3-coverage-what-we-have-and-what-is-missing)
4. [Where the data lives today](#4-where-the-data-lives-today): the inventory of sources that a unified strategy has to merge.
5. [Questions for the unified strategy](#5-questions-for-the-unified-strategy)

**Conventions.** *Observed* means I checked it on a live cluster of this repo (OCP 4.22, RHOAI 3.5.3, one NVIDIA L4 on a `g6.2xlarge`). *Docs* means the RHOAI 3.5 documentation. *Community* means material from the open-source projects or from public articles; several of those are written by vendors, so thresholds quoted from them are **examples, not standards**. *To validate* means the query uses metric names and labels that exist, but I have not run it against real traffic. The sources are listed at the end.

---

## 1. How the problem is framed

### 1.1 It is a stack of layers, not one dashboard

Every serious write-up on LLM monitoring splits the problem into layers, because each layer has different signals, different owners and a different time scale. The version that fits OpenShift AI best has five:

| # | Layer | The question it answers | Typical owner | Time scale |
|---|---|---|---|---|
| 0 | **Platform and hardware**: nodes, GPUs, drivers, quotas, queues | Is there capacity, and is it healthy? | Platform / SRE | minutes to hours |
| 1 | **Serving**: the inference engine and the router in front of the replicas | Is the model fast, saturated or wasting capacity? | ML platform | seconds to minutes |
| 2 | **Gateway and governance**: authentication, quotas, tenants | Who calls what, how much, and are the rules enforced? | Platform / product | minutes to days |
| 3 | **Application and quality**: traces, evaluations, guardrails, drift, user feedback | Is the answer good, safe and consistent? | AI engineers | per request to weeks |
| 4 | **Economics**: cost per token, idle capacity, chargeback | What does it cost, and who should pay? | FinOps / product | days to months |

Layers 0 to 2 are classic infrastructure monitoring with LLM-specific metrics. Layer 3 is what is new: classic monitoring tells you that something is wrong and where, but not whether the output was **good**, so teams add evaluation as a fourth pillar next to metrics, traces and logs. Layer 4 cuts across the others and is the one most teams add last and regret not adding earlier.

### 1.2 The four golden signals, adapted to LLMs

The SRE habit of watching latency, traffic, errors and saturation still applies, but each one splits in two for LLMs:

| Signal | For an LLM service it means |
|---|---|
| **Latency** | **TTFT** (time to first token: network, queue and prefill), **ITL/TPOT** (time between tokens: the decode phase) and **end-to-end** time. A request is roughly `TTFT + (output tokens − 1) × TPOT` |
| **Traffic** | requests per second **and tokens per second**. One long prompt can cost as much as many short ones, so requests alone mislead |
| **Errors** | `5xx` and timeouts, but also `429` (quota), aborted or cut answers (`finish_reason`), and guardrail blocks |
| **Saturation** | queue depth, **KV-cache usage**, preemptions and GPU activity. KV-cache usage is called the "north star" gauge in several guides; GPU utilization is not |

### 1.3 What most teams converge on

- **Percentiles, never averages.** p50, p95 and p99 over the raw events. The tail shows batch interference, cache evictions and pauses that an average hides.
- **SLOs per use case, then goodput.** *Goodput* is the share of requests that meet **all** the latency targets at once (for example TTFT under 500 ms, TPOT under 15 ms, end-to-end under 2 s), expressed as a fraction or as requests per second. It never exceeds the request rate, and it can fall while raw throughput keeps rising, which is exactly why it is preferred. As an illustration, one public guide proposes a p99 TTFT of 300 ms and ITL of 50 ms for interactive chat, tighter for voice and code completion; treat such numbers as a starting point to calibrate with your own load tests, not as a norm.
- **Diagnose in a fixed order.** Start with end-to-end latency to confirm there is a problem, split it into TTFT and generation time to find the phase, look at ITL to tell a uniformly slow stream from one that stalls, and only then look at load.
- **Match the fix to the failing metric.** TTFT improves with shorter prompts, shared-prefix caching and warm replicas (and prefill/decode disaggregation); TPOT improves with quantization, faster hardware or a smaller model; end-to-end improves by capping output length.
- **Weight the metrics by workload.** For agents, end-to-end time and TPOT over long outputs matter and TTFT barely does; for chat it is the reverse.
- **Page on symptoms, ticket on causes.** Alert a person on what users feel (TTFT or error ratio above the SLO, a target down). Send cause-level signals (a full KV cache, preemptions, one hot replica) to a ticket or chat channel. Thresholds should come from SLOs and representative load tests, not from constants copied from a blog.
- **Autoscale on queue depth, in-flight requests and KV-cache pressure, with a latency guardrail**, not on GPU utilization, which only reacts after the queue has formed. The llm-d autoscaling guide goes further and describes SLO-aware paths that compare the router's estimated TTFT/TPOT with the SLO.
- **Know your version.** Metric names change between releases (the KV-cache gauge was `vllm:gpu_cache_usage_perc` and is `vllm:kv_cache_usage_perc` in vLLM v1). Read your own `/metrics` output before writing alert rules.

### 1.4 GPUs: busy is not the same as useful

The `GPU utilization` number reports the share of time in which **at least one kernel was running**. It says the card was busy, not that the work was useful: a half-empty batch can show 70 % utilization at several times the cost per token of a well-tuned deployment. The recurring advice:

- Look at **SM and tensor-core activity, memory-bandwidth use and power** per card over days, not one number averaged over an instance.
- Use the idea of **effective utilization**: the part of the card's capability that turned into useful, billable work. Hidden idle time comes from KV-cache stalls, poor batching and waiting between requests.
- Track four things together: **allocated time**, **device busy time**, **work completed** (requests or tokens) and **service quality** (queue depth and latency percentiles). The goal is accepted work per dollar **while meeting the SLO**.
- Idle capacity is the main cost driver. One analysis frames it as: at 25 % utilization a model that costs 1.00 per million tokens when busy really costs 4.00 per million; self-hosting only beats an API above a utilization that depends on both prices (about 50 % in their example).

### 1.5 The gateway is the right place to meter consumers

Because the gateway sees every request, the community puts consumer accounting there:

- **Per consumer and per model:** request count, input and output tokens, latency, rejected requests (`429`) and an estimated cost.
- **One key per consumer** so that the question "who spent this" is answered when the call is made. Attribute by model, provider, environment, application, tenant and user.
- **Token-aware limits**, not request-rate limits, plus a **budget alert well before the limit** (one guide suggests 70 % of the monthly allowance rather than 90 %). The `429` count also tells you which customer deserves a bigger quota.
- **A structured per-request record** (identity, model, prompt and completion tokens, latency, cost) and idempotent ingestion if the data feeds billing.
- **Privacy by default.** Do not store prompts and answers unless there is a need and a control (the tracing tools record full content unless you turn it off).

### 1.6 Application layer: quality is the layer people skip

Production LLM apps rarely have a reference answer, so teams combine four reference-free techniques: an **LLM as judge** (calibrated against a human-labelled sample), **deterministic guardrail checks**, **heuristics** (refusals, length distribution, self-consistency) and **user feedback** (thumbs, edits, retries, escalations). The usual checklist:

- **Traces** end to end, with tokens and cost on each span and the exact model, prompt and router versions. OpenTelemetry defines `gen_ai.*` conventions for this (see below); they are still in *Development* status.
- **Drift:** rising negative feedback or hallucination rate, shifting answer-length or refusal distributions, creeping cost or latency, and falling scores on a fixed golden test set run nightly. It matters most after a model, prompt or provider change.
- **Guardrails** as a component with its own metrics: block rate, false positives, bypass attempts and the latency they add.
- **Cost per resolved task**, not only per request: a cheaper model with many retries can cost more.
- **Close the loop:** failures become regression tests, and releases are blocked when evaluation scores fall below a threshold.
- **Rollout order:** logging and latency first, quality evaluation second, safety and drift monitoring as the system matures.

### 1.7 The common vocabulary: OpenTelemetry GenAI conventions

The OpenTelemetry GenAI conventions (moved to their own repository in 2026 and marked *Development*) are the closest thing to a shared naming scheme. The server-side metrics are histograms in seconds:

| Metric | Meaning |
|---|---|
| `gen_ai.server.time_to_first_token` | time to the first token (queue time plus prefill) |
| `gen_ai.server.time_per_output_token` | decode time per token after the first |
| `gen_ai.server.request.duration` | whole request on the server |
| `gen_ai.client.operation.duration` | whole operation as the client sees it |
| `gen_ai.client.inference.usage.*` | token counters by category and modality (input, output, cache read and write, reasoning) |

vLLM, llm-d and OpenShift AI do not emit these names today; they have their own (`vllm:*`, `llm_d_epp_*`). They are useful as a **target vocabulary** if the aim is a vendor-neutral view or to feed an external tool.

---

## 2. Layer by layer: what to watch and where it lives in this stack

### The path of a request

```
client ──► MaaS gateway ──► Authorino ──► Limitador ──► llm-d gateway/EPP ──► vLLM pod ──► GPU
 (API key)  (Envoy/Istio)   (who are you)  (token quota)  (picks the replica)   (the engine)   (DCGM)
```

| Symptom the user reports | Look first at |
|---|---|
| `401` / `403` | layer 2: Authorino, subscriptions, authorization policies |
| `429` | layer 2: Limitador, the token quota of the subscription |
| Slow first token | layer 1: queue time, prefill time, KV cache, router |
| Slow stream (tokens one by one) | layer 1: inter-token latency, batch size, GPU saturation |
| `5xx` or timeouts | layer 1: gateway status codes, vLLM health; layer 0: GPU errors |
| "The model is down" | layer 1: ready pods and endpoints; layer 0: node, GPU, Kueue admission |
| Bad or inconsistent answers | layer 3: evaluations, traces, guardrails, model or prompt version |
| The invoice is too high | layer 4: allocated GPU-hours, idle time, tokens per hour |

### 2.1 Layer 2 · Gateway and MaaS: who consumes what

MaaS puts governance in front of the models: a subscription says how many tokens a group can use per time window, an authorization policy says who can reach a model, and every user calls with an API key bound to one subscription. This is the "meter the consumers at the gateway" pattern of section 1.5.

| Question | Signal | Source |
|---|---|---|
| Tokens consumed per subscription, user or model | `authorized_hits` | Limitador |
| Requests | `authorized_calls` | Limitador |
| Who is rate limited and how often | `limited_calls` (the `429`s) | Limitador |
| Is the quota well sized | rate-limit ratio = `limited_calls / (authorized_calls + limited_calls)` | derived |
| How close is each subscription to its limit | tokens used in the window divided by the configured limit (the limit is **not** exported as a metric, so keep it in a recording rule or a lookup) | derived |
| Is authentication healthy and fast | `auth_server_authconfig_duration_seconds_*`, `auth_server_authconfig_response_status` | Authorino |
| Are the policies enforced | `kuadrant_policies_enforced`, `kuadrant_allowed`, `kuadrant_denied`, `kuadrant_errors`, `kuadrant_hits`, `kuadrant_misses` | Kuadrant in the gateway pods |
| Is the gateway healthy and fast | `istio_requests_total` by `response_code`, `istio_request_duration_milliseconds_*` | Envoy / Istio |
| Is the control plane up | `limitador_up`, `kube_pod_status_phase` of `maas-api`, Authorino and the gateway pods | Limitador, kube-state-metrics |
| Are API keys working | `maas-api-metrics` and `maas-controller-metrics` PodMonitors; the PostgreSQL behind them | maas-api |

**Dimensions are configurable.** The usage counters carry `user`, `subscription` and `model`. `MaasTenantConfig.spec.telemetry` decides which exist (docs):

| Setting | Effect | Value in this repo |
|---|---|---|
| `telemetry.enabled` | telemetry on or off | `true` |
| `metrics.captureModelUsage` | adds `model` | `true` |
| `metrics.captureOrganization` | adds `organization` | `true` |
| `metrics.captureUser` | adds `user` (the authenticated id, **privacy implications**) | `true` |
| `metrics.captureGroup` | adds `group` | `false` |

Turning `captureUser` off removes the per-user view but keeps subscription and model. It is a conversation to have with each customer.

**Queries (to validate with traffic):**

```promql
# Tokens consumed in the last 24 h, per subscription and model
sum by (subscription, model) (increase(authorized_hits[24h]))

# Top 10 users by tokens
topk(10, sum by (user) (increase(authorized_hits[24h])))

# Share of requests that got a 429, per subscription
sum by (subscription) (rate(limited_calls[5m]))
  / (sum by (subscription) (rate(authorized_calls[5m])) + sum by (subscription) (rate(limited_calls[5m])))

# Authorization latency p95 (Authorino)
histogram_quantile(0.95, sum by (le) (rate(auth_server_authconfig_duration_seconds_bucket[5m])))

# Gateway errors and latency per backend service
sum by (destination_service_name) (rate(istio_requests_total{response_code=~"5.."}[5m]))
histogram_quantile(0.95, sum by (le, destination_service_name) (rate(istio_request_duration_milliseconds_bucket[5m])))
```

**How to read it**

- A subscription at 100 % of its quota is undersized or abused. Compare with the number of distinct users: one heavy user against a shared limit is a different problem from everybody hitting it.
- Tokens count prompt and completion together, and clients such as Open WebUI add extra requests per message (title, tags, follow-ups), so consumption can be several times what the person typed.
- `403` with a valid key usually means a subscription without an authorization policy; `429` on the first request means the reverse. Both resources are required for each model.
- Temporary keys last 1 hour; others can be permanent or expire. Revocations and expirations are an operational signal found in the `maas-api` logs, not a metric.

**Where to see it:** RHOAI dashboard → Observe & monitor → *Usage* (Technology Preview, with CSV export for showback); the *MaaS AI Engineer* and *MaaS Platform Admin* Grafana dashboards of this repo (`10-maas/4-grafana`). **Observed:** the `authorized_*`, `limited_calls` and `auth_server_*` series do not exist yet because no request has gone through MaaS (counters appear after the first evaluation), so those dashboards stay empty until you send traffic.

**Alerts:** `limitador_up == 0` or Authorino, `maas-api` or gateway pods not running; gateway `5xx` or `kuadrant_errors` above baseline; rate-limit ratio above a threshold; authorization p95 above ~100 ms; a subscription past ~70 % of its allowance; MaaS reported `Degraded` (it needs user workload monitoring).

### 2.2 Layer 1 · Serving: vLLM and llm-d

This layer applies almost everything in sections 1.2 and 1.3. There are two sources: the **vLLM engine** (what happens inside each replica) and the **llm-d endpoint picker, EPP** (how requests are routed across replicas). On OpenShift the controller creates the scrape configuration when you deploy an `LLMInferenceService` (docs): a `PodMonitor` (`kserve-llm-isvc-vllm-engine`) for the engines on port 8000 and a `ServiceMonitor` (`kserve-llm-isvc-scheduler`) for the EPP. Both were observed in `models-as-a-service`; they need **user workload monitoring** (docs).

Labels on the vLLM series (observed): `model_name`, `llm_isvc_name`, `llm_isvc_role` (`both`, `prefill`, `decode`), `llm_isvc_component`, `namespace`, `pod`.

**Saturation: is it full?**

| Metric | Meaning | How to read it |
|---|---|---|
| `vllm:num_requests_running` | requests in the batch now | compare with the configured maximum |
| `vllm:num_requests_waiting` | queued requests | the earliest saturation signal; sustained queue time or a backlog that keeps growing is what to alert on (short queues are normal in bursts) |
| `vllm:num_requests_waiting_by_reason` | why they wait | capacity versus deferral |
| `vllm:kv_cache_usage_perc` | KV cache in use (0–1) | the north-star gauge; evictions begin near 100 %, and a common practice is to alert when it stays high (some teams use 85 % sustained) |
| `vllm:num_preemptions_total` | requests evicted and recomputed | any steady rate means the cache is too small for the traffic; a leading indicator to lower concurrency or scale out |

**Latency** (histograms; use percentiles): `vllm:time_to_first_token_seconds`, `vllm:inter_token_latency_seconds`, `vllm:e2e_request_latency_seconds`, `vllm:request_queue_time_seconds` (if TTFT is high and this is high, it is capacity; if low, it is prefill), `vllm:request_prefill_time_seconds` and `vllm:request_decode_time_seconds` (where the time goes).

**Throughput and demand:** `vllm:prompt_tokens_total` and `vllm:generation_tokens_total` (rates are the throughput and the denominator of cost per token), `vllm:request_success_total` by `finished_reason` (a rising `length` share means answers are cut, `abort` means clients leave), `vllm:request_prompt_tokens` and `vllm:request_generation_tokens` (the workload shape), `vllm:iteration_tokens_total` (how full the batch is).

**Cache efficiency:** `vllm:prefix_cache_hits_total` over `vllm:prefix_cache_queries_total` (high is good: repeated system prompts and history are not recomputed), `vllm:prompt_tokens_cached_total`, `vllm:external_prefix_cache_*`.

**Newer and specialised series** present on this cluster: `vllm:estimated_flops_per_gpu_total` and `vllm:estimated_{read,write}_bytes_per_gpu_total` (estimated compute and memory traffic, a way to see whether the model is compute- or bandwidth-bound), `vllm:engine_sleep_state`, `vllm:cache_config_info` (static: cache size), and `vllm:nixl_*` for prefill/decode KV transfers.

```promql
# Latency percentiles per model
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:time_to_first_token_seconds_bucket[5m])))
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:inter_token_latency_seconds_bucket[5m])))
histogram_quantile(0.95, sum by (le, model_name) (rate(vllm:e2e_request_latency_seconds_bucket[5m])))

# Throughput (tokens per second)
sum by (model_name) (rate(vllm:generation_tokens_total[5m]))
sum by (model_name) (rate(vllm:prompt_tokens_total[5m]))

# Saturation
sum by (model_name) (vllm:num_requests_waiting)
max by (model_name, pod) (vllm:kv_cache_usage_perc)
sum by (model_name) (rate(vllm:num_preemptions_total[5m]))

# Prefix-cache hit ratio and why requests end
sum by (model_name) (rate(vllm:prefix_cache_hits_total[5m])) / sum by (model_name) (rate(vllm:prefix_cache_queries_total[5m]))
sum by (finished_reason) (rate(vllm:request_success_total[5m]))
```

**Goodput.** Neither vLLM nor OpenShift AI publishes goodput, but the histograms allow an approximation: the share of requests under each target. It needs a bucket boundary at the target value (vLLM can change the boundaries with `--custom-histogram-buckets`; long lists inflate storage and scrape size).

```promql
# Share of requests with TTFT <= 0.5 s and with end-to-end <= 2 s (needs those bucket boundaries)
sum(rate(vllm:time_to_first_token_seconds_bucket{le="0.5"}[5m])) / sum(rate(vllm:time_to_first_token_seconds_count[5m]))
sum(rate(vllm:e2e_request_latency_seconds_bucket{le="2.5"}[5m])) / sum(rate(vllm:e2e_request_latency_seconds_count[5m]))
```

The real multi-constraint goodput (all targets at once, per request) needs per-request data, which is a job for traces.

**The llm-d EPP and gateway.** The EPP chooses the replica using queue depth, KV-cache use and prefix-cache locality; its metrics say whether routing is healthy and whether it helps.

| Group | Metrics | What it answers |
|---|---|---|
| Pool health | `llm_d_epp_ready_endpoints`, `inference_pool_ready_pods`, average KV-cache use and queue size of the pool, `llm_d_epp_per_endpoint_queue_size` | how many replicas are ready and how loaded the pool is |
| Routing | request totals and errors per objective, `llm_d_inference_scheduler_disagg_decision_total` | how many requests were routed, how many failed, how often prefill/decode was split |
| Routing cost | scheduler end-to-end and plugin durations, `llm_d_epp_prefix_indexer_size` | how long choosing a replica takes |
| Flow control (when enabled) | `llm_d_epp_flow_control_*` (queue size, saturation, capacity utilization) | admission and queuing in the router |
| Prefix cache prediction | `llm_d_epp_prefix_predicted_cached_tokens`, `…_best_available_cached_tokens` | whether routing is finding cached prefixes |
| User-perceived request metrics | the `llm_d_epp_` request series (TTFT, TPOT, ITL, errors, duration) | latency as the user sees it: it includes scheduler wait and network, so it is **higher than the engine's** and is the right basis for an SLO |

**Naming (confirmed).** llm-d moved the EPP metrics to the `llm_d_epp_*` prefix. Red Hat's documentation states that the old `inference_objective_*`, `inference_extension_*` and `inference_pool_*` prefixes are **deprecated but still available** for backward compatibility. Observed on the cluster: both families exist (`llm_d_epp_info` next to `inference_extension_info`). Dashboards built on the old names, including the llm-d ones in this repo, keep working for now but should be migrated. Upstream llm-d also publishes a dedicated *router* dashboard (pool, objective, flow control) that this repo does not have.

**Reading the two together**

| What you see | Likely cause | Action |
|---|---|---|
| TTFT up, queue time up, `num_requests_waiting > 0`, KV cache high | replicas saturated | add replicas or a bigger GPU; check the load is spread evenly |
| TTFT up, queue time low | long prompts (prefill-bound) | prefill/decode disaggregation, shared-prefix caching, prompt limits |
| ITL up, queue low | decode-bound or batch too big | lower concurrency per replica or a faster GPU |
| Preemptions climbing | KV cache too small | lower max model length or concurrency, more memory per replica |
| One pod much busier than the rest | routing not balancing, or a bad node | EPP decisions, readiness, hit ratio per pod |
| EPP ready endpoints below replicas | replicas not ready or excluded | pod readiness, model load time, Kueue gang-scheduling timeout |
| EPP latency much higher than vLLM latency | time lost in the scheduler or network | scheduler plugin duration, gateway latency |
| Cache hit ratio near 0 on chat traffic | routing not cache-aware, or prompts differ | EPP scoring configuration |

**Autoscaling signals.** If you autoscale (the platform ships WVA as Technology Preview, `kserve.wva`, and KEDA integration arrives in 3.6 EA), the signals are queue depth, in-flight requests and KV-cache pressure, ideally compared with the SLO, not GPU utilization.

**Where to see it:** RHOAI dashboard → Observe & monitor (needs the Cluster Observability Operator and the `metrics` section of `DSCInitialization`): *Models*, *LLM Traffic*, *LLM Performance* and *LLM Utilization*, which read from the **platform Prometheus**. The Grafana dashboards of this repo (`09-llm-d`) read from the cluster one. **Observed today:** only the simulator serves, so the vLLM series are the small subset it emits (requests, KV cache, cache config); the full engine, latency and EPP picture appears when a real model such as `gpt-oss-20b` receives traffic.

**Alerts:** TTFT or ITL p95 above the SLO and error ratio above baseline (page); `num_requests_waiting > 0` for 5 minutes, KV cache above ~0.9 for 10 minutes, preemption rate above 0, ready pods below desired replicas (ticket).

### 2.3 Layer 0 · GPUs and capacity

**Hardware behaviour: DCGM.** The NVIDIA GPU Operator runs the DCGM exporter (`ServiceMonitor nvidia-dcgm-exporter`, enabled in the `ClusterPolicy`). The cluster Prometheus scrapes it because the operator namespace carries `openshift.io/cluster-monitoring: 'true'`, so it does not need user workload monitoring. Labels (observed): `hostname`, `gpu`, `UUID`, `modelName`, `device`, `pci_bus_id`, driver version. `pod` and `namespace` are the exporter's, **not the workload's** (see "who owns the card" below).

| Metric | Meaning | How to read it |
|---|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | share of time any kernel ran | coarse (section 1.4) |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | engine and tensor cores really active | better indicators of useful work |
| `DCGM_FI_PROF_DRAM_ACTIVE` | memory bandwidth in use | decoding is usually memory-bound: high here with low tensor activity is expected |
| `DCGM_FI_DEV_FB_USED`, `FB_FREE`, `FB_RESERVED` | framebuffer in MiB | **not a demand signal**: vLLM pre-allocates most memory, so it looks full from the start; use `vllm:kv_cache_usage_perc` |
| `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | power (W) and cumulative energy (mJ) | load proxy, kWh and carbon |
| `DCGM_FI_DEV_GPU_TEMP`, `MEMORY_TEMP`, `SM_CLOCK`, `MEM_CLOCK` | thermal and clock state | throttling shows as clocks dropping while temperature climbs |
| `DCGM_FI_PROF_PCIE_{RX,TX}_BYTES`, `DCGM_FI_DEV_MEM_COPY_UTIL` | data movement | transfer bottlenecks (model loading, multi-GPU) |
| `DCGM_FI_DEV_*REMAPPED_ROWS`, `ROW_REMAP_FAILURE`, `PCIE_REPLAY_COUNTER` | hardware health | any increase deserves attention; a remap failure means replacing the card |

RHOAI also publishes `accelerator_gpu_utilization`, `accelerator_memory_used_bytes`, `accelerator_power_usage_watts` and `accelerator_temperature_celsius`, derived from DCGM, which feed its *Cluster* and *Models* dashboards. The operator itself exposes health (`gpu_operator_node_driver_ready`, `gpu_operator_node_device_plugin_devices_total`, `gpu_operator_gpu_nodes_total`, `gpu_operator_reconciliation_status`): check those first when a GPU node is up but no pod can use the card.

```promql
DCGM_FI_DEV_GPU_UTIL
avg by (hostname, gpu) (DCGM_FI_PROF_PIPE_TENSOR_ACTIVE)
DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
DCGM_FI_DEV_POWER_USAGE
# kWh per day from the cumulative counter in mJ (1 kWh = 3.6e9 mJ)
sum by (hostname) (increase(DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION[1d])) / 3.6e9
```

**Who owns the card.** DCGM tells you how a card behaves, not who uses it. `kube_pod_container_resource_requests{resource="nvidia_com_gpu"}` (observed) gives the GPUs held per pod and namespace. With one GPU per pod you can match by node (DCGM `hostname` equals the pod's node); with time slicing or MIG the match is per slice and needs the exporter's pod mapping, which I did **not** find on the series of this cluster, so validate it before trusting per-pod numbers. The community advice is the same: put an owner label on every GPU workload.

```promql
# GPUs held by running pods, per namespace
sum by (namespace) (
  kube_pod_container_resource_requests{resource="nvidia_com_gpu"}
  * on (namespace, pod) group_left () (kube_pod_status_phase{phase="Running"} == 1))
# GPUs in the cluster
sum(kube_node_status_allocatable{resource="nvidia_com_gpu"})
```

**Quota and queueing (Kueue).** With the reserved-spot design this is a key view. Observed metrics: `kueue_cluster_queue_resource_usage` against `kueue_cluster_queue_nominal_quota` (per `cluster_queue`, `flavor`, `resource`), `kueue_cluster_queue_borrowing_limit`, `kueue_pending_workloads` and `kueue_local_queue_pending_workloads` (who waits), `kueue_admission_wait_time_seconds` (how long), `kueue_evicted_workloads_total` (batch work preempted to give GPU back to serving). `scheduler_pending_pods` and the pod events tell "no free GPU" from "no quota".

```promql
sum by (cluster_queue) (kueue_cluster_queue_resource_usage{resource="nvidia.com/gpu"})
sum by (cluster_queue) (kueue_cluster_queue_nominal_quota{resource="nvidia.com/gpu"})
sum by (cluster_queue) (kueue_pending_workloads)
sum by (cluster_queue) (increase(kueue_evicted_workloads_total[1d]))
```

**Alerts:** GPU node `NotReady` or `SchedulingDisabled`, `gpu_operator_node_driver_ready == 0` or fewer devices than expected (capacity gone); remapped rows or PCIe replays increasing, or high temperature with falling clocks; held GPUs with utilization near 0 for hours (paying for idle cards); pending Kueue workloads for a long time or frequent evictions.

### 2.4 Layer 4 · Cost

No component in OpenShift AI exports a cost metric. The community converges on three ideas: **cost is mostly allocated, not used** (a held GPU costs the same idle); **cost per token is the number that matters**, and it depends on utilization; and **attribution needs an owner on every workload**.

**The OpenCost route (new, worth evaluating first).** OpenCost 1.121.0 added inference cost tracking for llm-d and vLLM. It reads the vLLM token counters (`vllm:prompt_tokens_total`, `vllm:generation_tokens_total`) together with its own GPU cost allocation and publishes, with labels `model_name`, `model_version`, `namespace`, `cost_basis` (`usage` or `allocation`) and `workload_type`:

- `llm_total_hourly_cost`: cost per hour per model.
- `llm_cost_per_million_tokens`: blended cost per million tokens, with input and output broken out (input drives prefill, output drives decode).

It computes two bases. **Allocation-based** is the full cost of keeping the model available (reserved GPU memory, plus a share of the EPP, the gateway proxy and the KV-cache storage, which llm-d components label for attribution). **Usage-based** is only the cost consumed while serving. Their ratio is the utilization (for example 1.00 / 4.00 = 25 %), and the gap is the cost of keeping the model warm. Its own table is a good reading guide: high allocation and low usage per token means a utilization problem (consolidate or share); high on both means reconsider the model; low on both is well sized. llm-d's documentation has a *Track Inference Cost* page for this. Status noted by the project: wasted-GPU measurement, better idle detection and team attribution are still in progress, and I have not tested it on this stack.

**The manual route** (and a sanity check for any tool). Derive it from GPU-hours held, the price of a GPU-hour and the tokens served:

1. **Price of a GPU-hour.** Take the on-demand or reserved price of the instance type and region (here `g6.2xlarge` in `eu-central-1`, one L4). The instance type is a label on the node (`kube_node_labels{label_beta_kubernetes_io_instance_type="g6.2xlarge"}`, observed), so a price table keyed by it can be joined in. On multi-GPU instances divide by the number of GPUs. Cloud billing reports lag by a day or two, which is why the cost is estimated from metrics for real-time visibility.
2. **Allocated cost** = GPU-hours **held** × price. 3. **Efficiency** = held versus used.

```promql
# GPU-hours held per namespace in the last day (multiply by the price per GPU-hour; 1.0 is a placeholder)
sum by (namespace) (avg_over_time(kube_pod_container_resource_requests{resource="nvidia_com_gpu"}[1d])) * 24 * 1.0

# Cost per million generated tokens (price per GPU-hour / million tokens per hour)
1.0 / (sum(rate(vllm:generation_tokens_total[1h])) * 3600 / 1e6)

# Idle share of the held GPU time
1 - avg(DCGM_FI_DEV_GPU_UTIL) / 100
```

**Chargeback by consumer** is the bridge between layers 2 and 4: split each model's cost by every subscription's or user's share of that model's tokens, `authorized_hits{subscription=...} / sum(authorized_hits{model=...})`. It is the main reason layers 2 and 4 should live in the same place. Energy and carbon follow from `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` times a grid factor. Kubecost and Red Hat cost management are other candidates; I have not tested either against GPU workloads on this stack.

**Alerts:** cost per day or per million tokens above a budget, utilization of a held GPU below a floor for a sustained period, and the subscription budget alerts of section 2.1.

### 2.5 Layer 3 · Application and quality

This is the layer the OpenShift AI platform dashboards do not cover, and where most teams are thinnest. What the stack offers today:

| Need | What exists | Notes |
|---|---|---|
| Traces end to end | OpenTelemetry collector (`data-science-collector`, ports 4317 and 4318) and Tempo in the platform stack; `genAiTracing` flag of the dashboard; MLflow tracing; llm-d distributed tracing (Developer Preview in 3.4) | needs the application or the router to emit traces; the stack only provides the receiver and the store |
| LLM observability for apps | **Langfuse** (optional chart in this repo, `INSTALL_LANGFUSE`): traces, token and cost per trace, prompts, evaluation scores | the self-hosted analogue of what the community tools offer |
| Quality and regression | **EvalHub** (providers such as lm-evaluation-harness, garak, ragas, lighteval, deepeval, inspect, ibm-clear; collections such as safety-and-fairness), results in MLflow, EvalCards | batch evaluation, not continuous production scoring |
| Guardrails | NeMo Guardrails (GA in 3.4, with built-in OpenTelemetry support per the release notes); TrustyAI | block rate and guardrail latency should be exposed as metrics; to validate on this stack |
| Drift | none out of the box | run a golden test set on a schedule through EvalHub and compare the scores |
| User feedback | application-specific (for example the thumbs of the chat UI) | not collected by the platform |

What to watch here: traces with tokens and cost per span and the model and prompt version; quality scores attached to trace ids; refusal and answer-length distributions; guardrail block and false-positive rates and their added latency; nightly golden-set scores; negative-feedback rate; and cost per resolved task. Keep content capture (prompts and answers) opt-in.

---

## 3. Coverage: what we have and what is missing

Compared with what the community watches (section 1), for this stack:

| Signal | Status | Where it comes from, or what is missing |
|---|---|---|
| TTFT, ITL, end-to-end percentiles | **Covered** | vLLM histograms; RHOAI *Models* and *LLM Performance*; Grafana |
| Queue depth, KV cache, preemptions | **Covered** | vLLM gauges and counters |
| Goodput and SLO attainment | **Missing** | needs recording rules over the histogram buckets (section 2.2) and bucket boundaries at the SLO values |
| Router health and user-perceived latency | **Covered, naming to migrate** | EPP `llm_d_epp_*`; dashboards still use the deprecated prefixes |
| Tokens and requests per consumer, `429`s | **Covered once traffic flows** | Limitador counters; RHOAI *Usage*; Grafana |
| Quota consumed versus limit, budget alerts | **Partial** | the limit is not a metric; needs a recording rule or lookup |
| Cost per consumer | **Missing** | derivable by splitting model cost by token share |
| GPU busy, tensor activity, memory bandwidth, power | **Covered** | DCGM (profiling fields included) |
| Effective utilization, idle waste | **Partial** | derivable from allocation versus activity; estimated flops/bytes from vLLM help |
| GPU to workload attribution | **To validate** | join by node; exporter pod labels not seen here |
| Cost per token and per hour | **Missing natively** | OpenCost 1.121+ is the candidate; manual formulas as a fallback |
| Autoscaling signals | **Partial** | WVA (Technology Preview) and KEDA (3.6 EA) use queue, in-flight and KV-cache signals |
| Traces end to end | **Partial** | receiver and store exist (OTel collector, Tempo); instrumentation is the gap |
| Output quality in production | **Partial** | EvalHub and MLflow in batch; Langfuse for traces and scores |
| Guardrail metrics | **Partial** | NeMo OpenTelemetry support; confirm what is exposed |
| Drift | **Missing** | scheduled golden set through EvalHub |
| User feedback | **Missing** | application-specific |

---

## 4. Where the data lives today

The inventory that a unified view has to merge. Observed on the cluster of this repo:

| # | Source | What it stores | Who reads it | How it is fed |
|---|---|---|---|---|
| A | **OpenShift monitoring + user workload monitoring** (`thanos-querier` in `openshift-monitoring`) | everything scraped from the cluster and user namespaces: DCGM and GPU Operator, kube-state-metrics, Kueue, Kuadrant and the Istio gateways, the llm-d EPP, the vLLM engines (both `vllm:` and `kserve_vllm:`), about 3,900 metric names | OpenShift console → Observe; the Grafana of this repo (datasource `prometheus-grafana`) | `ServiceMonitor` and `PodMonitor`; user workload monitoring on (`INSTALL_MONITORING`) |
| B | **RHOAI platform stack** (`data-science-monitoringstack` and `data-science-thanos-querier` in `redhat-ods-monitoring`, plus Perses) | a curated subset of about 850 names: `kserve_vllm:` (16 metric names), raw `vllm:`, `istio_*`, the four `accelerator_*`, `limitador_up` | RHOAI dashboard → Observe & monitor (Cluster, Models, Usage, LLM Traffic, Performance, Utilization) | OpenTelemetry collector with a target allocator; workloads opt in with `monitoring.opendatahub.io/scrape=true`; can export through `DSCInitialization.spec.monitoring.metrics.exporters` |
| C | **Tempo** (`redhat-ods-monitoring` and `openshift-tempo`) | traces (90 days, sampling 0.1 in this repo) | Grafana (datasource `tempo`), Perses | OTLP into the collector |
| D | **Grafana of this repo** (`INSTALL_GRAFANA`) | nothing of its own: 5 llm-d and 2 MaaS dashboards over A and C | people | Grafana operator, `GrafanaDashboard` |
| E | **NVIDIA GPU console plugin** | the GPU view of the OpenShift console | admins | DCGM through A |
| F | **MLflow, EvalHub, Langfuse** | runs, traces, evaluation results, prompts | data scientists, evaluators | their own APIs |

Why it feels fragmented:

- The same metric exists twice with different names: vLLM appears as `vllm:*` and `kserve_vllm:*`. The RHOAI dashboards use the second; the Grafana dashboards of this repo use the first.
- MaaS consumption is not in B (only `limitador_up` is). The RHOAI *Usage* dashboard and our Grafana dashboards may not read the same store; confirm it when MaaS has traffic.
- The GPU dashboards of the platform show utilization, not cost. Nothing in A or B computes cost or cost per token.
- User workload monitoring is a prerequisite for several things (llm-d scraping, MaaS usage), while B needs the Cluster Observability, Tempo and OpenTelemetry operators.

## 5. Questions for the unified strategy

The research suggests a layout most teams end up with, which we can use to frame the decisions: **one row per layer** on a single page (SLO attainment, goodput and error budget at the top; consumers; serving; GPUs and capacity; cost per million tokens), with the application layer (traces, evaluations) in a dedicated tool linked by model, namespace and trace id.

1. **One store or one pane?** Feed everything into one Prometheus (B can export with `metrics.exporters`; A has its own Thanos), or keep both and put one dashboard layer on top that queries both.
2. **Which dashboard layer is the home?** The RHOAI native one (Perses: supported, in the product, but a fixed set of views) or Grafana (flexible, and today the only place where governance and cost could be joined).
3. **Which naming do we standardise on** (`vllm:` or `kserve_vllm:`), and when do we migrate the dashboards from the deprecated EPP prefixes to `llm_d_epp_*`.
4. **Where does cost live?** OpenCost 1.121+ (to evaluate on this stack), recording rules over the formulas of section 2.4, or both (the rules as a cross-check).
5. **SLOs first.** Which targets per use case (chat, agents, batch), so goodput, alerts and autoscaling share one definition.
6. **Privacy and retention:** per-user labels (`captureUser`), content capture in traces, and how long to keep per-user consumption.
7. **Alerting:** one Alertmanager and one routing, symptoms to a person and causes to a queue, instead of alerts spread over A and B.
8. **How far into layer 3** do we go for the demo: traces and Langfuse only, or scheduled evaluations and drift as well.

## References

OpenShift AI and this repo

- RHOAI 3.5, *Managing OpenShift AI*, chapter *Manage observability*; *Deploy models using Distributed Inference with llm-d*, chapter *Monitor llm-d deployments*; *Govern LLM access with Models-as-a-Service*; *Evaluating AI systems* (EvalHub).
- Red Hat AI Inference 3.5, [*Monitor llm-d deployments*](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.5/html/monitor_and_troubleshoot_distributed_inference_with_llm-d_deployments/monitoring-llmd-deployments) (metric families, deprecated EPP prefixes, troubleshooting).
- In this repo: `README.md` (section *Metrics and user-workload monitoring*), `rhoai-installation-chart/templates/10-maas/3-observability`, the dashboards under `rhoai-installation-chart/files/`.

Community and projects

- llm-d: [Metrics](https://llm-d.ai/docs/dev/operations/observability/metrics), [Router (EPP) metrics](https://llm-d.ai/docs/dev/operations/observability/router-metrics), [Dashboards](https://llm-d.ai/docs/operations/observability/dashboards), [Autoscale inference pools](https://llm-d.ai/docs/operations/autoscaling), [router metrics reference](https://github.com/llm-d/llm-d-router/blob/main/docs/metrics.md).
- vLLM: [Metrics design](https://docs.vllm.ai/en/stable/design/metrics/), [Production metrics](https://docs.vllm.ai/en/stable/usage/metrics/).
- OpenCost: [inference cost tracking for llm-d](https://opencost.io/blog/opencost-llmd-inference-cost/) (also on the [CNCF blog](https://www.cncf.io/blog/2026/08/05/opencost-1-121-0-first-of-a-kind-kubernetes-inference-cost-tracking/)).
- OpenTelemetry: [GenAI metrics](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-metrics.md).
- Inference metrics and SLOs: [BentoML LLM Inference Handbook](https://bentoml.com/llm/inference-optimization/llm-inference-metrics), [Anyscale](https://docs.anyscale.com/llm/serving/benchmarking/metrics), [ClickHouse](https://clickhouse.com/resources/engineering/llm-inference-latency), [Spheron SLO guide](https://www.spheron.network/blog/llm-inference-slo-ttft-itl-latency-budget-guide-2026/), [Inference Engineering](https://inference-engineering.com/guide-production-metrics.html).
- vLLM in production: [Monitoring vLLM in Production](https://akrisanov.com/vllm-metrics/), [Parseable](https://www.parseable.com/blog/vllm-inference-metrics-otel).
- GPU cost and utilization: [Lightbits, effective utilization](https://www.lightbitslabs.com/blog/the-utilization-illusion-how-to-measure-effective-utilization-of-gpus-and-their-impact-on-tokenomics/), [Datarekha](https://datarekha.com/blog/your-gpus-are-mostly-idle-finops/), [Finout](https://www.finout.io/blog/gpu-cost-optimization-and-monitoring-a-practical-guide).
- AI gateways: [Envoy AI Gateway usage-based rate limiting](https://aigateway.envoyproxy.io/docs/capabilities/traffic/usage-based-ratelimiting/), [MLflow, AI gateway architecture](https://mlflow.org/articles/ai-gateway-architecture-a-guide-for-technical-teams/), [WSO2, AI gateway observability](https://wso2.com/api-platform/learn/ai-gateway-observability).
- LLM application observability: [Inference.net](https://inference.net/content/llm-observability-monitoring-production-deployments/), [Patronus AI](https://www.patronus.ai/llm-testing/llm-observability), [OpenObserve](https://openobserve.ai/blog/llm-monitoring-best-practices/).

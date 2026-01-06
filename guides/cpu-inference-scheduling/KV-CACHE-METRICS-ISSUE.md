# KV Cache Metrics Not Showing in Grafana - Root Cause Analysis

**Date**: January 5, 2026
**Issue**: Per-Pod Cache Hit Rates and KV Cache Hit Rate panels show no activity in Grafana dashboard
**Status**: ROOT CAUSE IDENTIFIED - Architecture Limitation

---

## Root Cause

**Prefix caching is NOT supported on ARM64 CPUs with vLLM V1 backend.**

### Evidence from vLLM Logs

```
INFO [arg_utils.py:1348] Prefix caching is not supported for ARM and POWER, S390X and RISC-V CPUs; disabling it for V1 backend.
```

### Evidence from Metrics Endpoint

```bash
$ kubectl exec ... -- curl -s http://localhost:8200/metrics | grep cache_config

vllm:cache_config_info{
  ...
  enable_prefix_caching="False",
  ...
}
```

### Affected Metrics (All Zero)

```
vllm:prefix_cache_queries_total = 0.0
vllm:prefix_cache_hits_total = 0.0
vllm:external_prefix_cache_queries_total = 0.0
vllm:external_prefix_cache_hits_total = 0.0
```

---

## Why This Happened

1. **Platform**: You're running on **Apple Silicon (ARM64)** with Minikube + Podman
2. **vLLM Version**: v0.11.1rc7 with V1 backend
3. **Architecture Limitation**: vLLM's V1 backend doesn't support prefix caching on ARM CPUs
4. **Auto-Disabled**: vLLM automatically disabled prefix caching at startup

---

## What Metrics ARE Available

Despite prefix caching being disabled, you still have these useful metrics:

### ✅ Working Metrics

#### 1. **KV Cache Usage**
```
vllm:kv_cache_usage_perc - Current KV cache utilization percentage
```

#### 2. **Request Metrics**
```
vllm:num_requests_running - Requests currently being processed
vllm:num_requests_waiting - Requests in queue
vllm:request_success_total{finished_reason="stop|length|abort"} - Completed requests
```

#### 3. **Token Metrics**
```
vllm:prompt_tokens_total - Total prompt tokens processed
vllm:generation_tokens_total - Total tokens generated
```

#### 4. **Latency Metrics** (These are populated!)
```
vllm:time_to_first_token_seconds - TTFT histogram
vllm:e2e_request_latency_seconds - End-to-end request latency
```

#### 5. **Throughput Metrics**
```
vllm:request_params_best_of - Request parameters
vllm:request_params_n - Number of completions
```

---

## Solutions

### Option 1: Accept Limitation (Recommended for Testing)

**Use the metrics that ARE available:**

1. **KV Cache Utilization** - Shows how full the cache is
2. **Request Queue Depth** - Shows load balancing across replicas
3. **Latency Metrics** - TTFT and E2E latency ARE being tracked
4. **Throughput** - Tokens/sec and requests/sec

**Modified Benchmark Script**: Focus on metrics that work on ARM64.

### Option 2: Deploy on x86_64/AMD64

To get full KV cache hit/miss metrics, you would need to:

1. **Use x86_64 architecture** (not ARM64)
2. **Options**:
   - Linux workstation with Intel/AMD CPU
   - Cloud VM (AWS EC2, GCP, Azure) with x86_64
   - Intel Mac (not Apple Silicon)

### Option 3: Use V0 Backend (Not Recommended)

The older V0 backend might support prefix caching on ARM, but:
- V1 backend is faster and more efficient
- V0 is deprecated
- Not worth the tradeoff for testing

---

## What You Can Test Instead

### Focus on These Dashboard Panels:

1. ✅ **KV Cache Utilization** (`vllm:kv_cache_usage_perc`)
   - Shows cache memory usage over time
   - Increases with concurrent requests

2. ✅ **Request Queue Depth** (`vllm:num_requests_waiting`)
   - Tests load balancing
   - Shows EPP routing effectiveness

3. ✅ **Time to First Token (TTFT)**
   - Histogram of first token latency
   - Shows inference performance

4. ✅ **End-to-End Latency**
   - Total request completion time
   - Good for performance testing

5. ✅ **Requests Per Second**
   - Throughput metric
   - Tests system capacity

6. ✅ **Tokens Per Second**
   - Generation speed
   - CPU inference performance

### Modified Benchmark Goals:

Instead of testing KV cache hits, focus on:

- **Load Balancing**: Requests distributed across 2 replicas
- **Queue Management**: EPP routing based on queue depth
- **Throughput**: Sustained requests/sec and tokens/sec
- **Latency**: TTFT and E2E latency under load
- **Resource Utilization**: CPU and memory usage

---

## Verification Commands

### Check Current Metrics:

```bash
# Get all available vLLM metrics
kubectl get pods -n llm-d-cpu-inference -l llm-d.ai/inferenceServing=true -o name | \
  head -1 | xargs -I {} kubectl exec -n llm-d-cpu-inference {} -c vllm -- \
  curl -s http://localhost:8200/metrics | grep "^vllm:" | grep -v "#"

# Check cache config
kubectl get pods -n llm-d-cpu-inference -l llm-d.ai/inferenceServing=true -o name | \
  head -1 | xargs -I {} kubectl exec -n llm-d-cpu-inference {} -c vllm -- \
  curl -s http://localhost:8200/metrics | grep "cache_config_info"

# Check TTFT metrics (should have data)
kubectl get pods -n llm-d-cpu-inference -l llm-d.ai/inferenceServing=true -o name | \
  head -1 | xargs -I {} kubectl exec -n llm-d-cpu-inference {} -c vllm -- \
  curl -s http://localhost:8200/metrics | grep "time_to_first_token"
```

### Verify Prometheus is Scraping:

```bash
# Check if Prometheus can see the metrics
# Port-forward Prometheus
kubectl port-forward -n llm-d-monitoring svc/llmd-kube-prometheus-stack-prometheus 9090:9090 &

# Query in browser: http://localhost:9090
# Search for: vllm:time_to_first_token_seconds
# Should show data from both replicas
```

---

## Grafana Dashboard Adjustments

### Panels That Will Work:

- ✅ **KV Cache Usage Percentage** (shows utilization, not hits)
- ✅ **Request Queue Depth**
- ✅ **Time to First Token (TTFT)**
- ✅ **Request Latency (E2E)**
- ✅ **Requests Per Second**
- ✅ **Tokens Per Second**
- ✅ **Active Requests**

### Panels That Won't Work (ARM64 Limitation):

- ❌ **Per-Pod Cache Hit Rate** (requires prefix_cache_hits)
- ❌ **KV Cache Hit Rate** (requires prefix_cache_queries)
- ❌ **Prefix Cache Efficiency** (requires prefix caching enabled)

---

## Recommendation

**For this deployment (Apple Silicon + CPU inference):**

1. **Accept the limitation** - Prefix caching is not supported on ARM64
2. **Use alternative metrics** - Focus on latency, throughput, and queue depth
3. **Run the modified benchmark** (see `benchmark-alternative-metrics.sh`)
4. **Monitor what works**:
   - Load balancing across replicas
   - Request queue management
   - Inference latency and throughput
   - Resource utilization

**For production deployments with KV cache metrics:**
- Deploy on x86_64/AMD64 Linux systems
- Use Intel-based machines or cloud VMs
- GPU acceleration will also be available on x86_64

---

## Summary

| Metric Type | Status | Reason |
|-------------|--------|--------|
| Prefix Cache Hits/Misses | ❌ Not Available | ARM64 architecture limitation |
| KV Cache Usage % | ✅ Available | Works on all architectures |
| Request Latency (TTFT, E2E) | ✅ Available | Works on all architectures |
| Queue Depth | ✅ Available | Works on all architectures |
| Throughput (tokens/sec) | ✅ Available | Works on all architectures |
| Load Balancing | ✅ Available | EPP routing metrics work |

**Bottom Line**: Your deployment is working correctly. The KV cache hit/miss metrics are unavailable due to ARM64 CPU architecture limitations in vLLM V1 backend, not a configuration issue.

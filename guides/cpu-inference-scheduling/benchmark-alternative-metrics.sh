#!/usr/bin/env bash

#######################################
# Alternative Metrics Benchmark for ARM64
#
# This benchmark focuses on metrics that WORK on ARM64/Apple Silicon:
# - KV cache utilization (not hit rate)
# - Request queue depth
# - Time to first token (TTFT)
# - End-to-end latency
# - Throughput (requests/sec, tokens/sec)
# - Load balancing across replicas
#
# Note: Prefix caching is NOT supported on ARM64 CPUs with vLLM V1 backend.
# Therefore, cache hit/miss metrics will always be zero.
#
# Usage:
#   ./benchmark-alternative-metrics.sh [duration_seconds]
#######################################

set -euo pipefail

# Configuration
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8000}"
MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
DURATION="${1:-300}"  # Default 5 minutes
NAMESPACE="llm-d-cpu-inference"

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')]${NC} $1"
}

log_metric() {
    echo -e "${CYAN}[$(date +'%H:%M:%S')]${NC} 📊 $1"
}

# Test 1: Light load (measure baseline latency)
test_baseline_latency() {
    log_info "Test 1: Baseline Latency (10 sequential requests)..."

    for i in {1..10}; do
        local start=$(date +%s%N)
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 5.\"}],
                \"max_tokens\": 50
            }" > /dev/null 2>&1
        local end=$(date +%s%N)
        local duration_ms=$(( (end - start) / 1000000 ))
        log_metric "Request $i latency: ${duration_ms}ms"
        sleep 0.5
    done

    log_success "Test 1 complete - Check TTFT histogram in Grafana"
}

# Test 2: Concurrent load (measure queue depth and load balancing)
test_concurrent_load() {
    local concurrency=$1
    log_info "Test 2: Concurrent Load ($concurrency parallel requests)..."

    for i in $(seq 1 $concurrency); do
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"Explain machine learning in 2 sentences.\"}],
                \"max_tokens\": 80
            }" > /dev/null 2>&1 &
    done

    wait
    log_success "Test 2 complete - Check queue depth and load balancing"
}

# Test 3: Burst pattern (measure queue management)
test_burst_pattern() {
    log_info "Test 3: Burst Pattern (3 bursts of 20 requests)..."

    for burst in {1..3}; do
        log_metric "Sending burst $burst..."
        for i in {1..20}; do
            curl -s "$GATEWAY_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"$MODEL\",
                    \"messages\": [{\"role\": \"user\", \"content\": \"What is AI?\"}],
                    \"max_tokens\": 40
                }" > /dev/null 2>&1 &
        done
        wait
        log_metric "Burst $burst completed"
        sleep 5
    done

    log_success "Test 3 complete - Check request queue depth spikes"
}

# Test 4: Sustained throughput (measure tokens/sec)
test_sustained_throughput() {
    local duration=$1
    log_info "Test 4: Sustained Throughput (${duration}s of continuous requests)..."

    local end_time=$(($(date +%s) + duration))
    local request_count=0

    while [ $(date +%s) -lt $end_time ]; do
        for i in {1..5}; do
            curl -s "$GATEWAY_URL/v1/chat/completions" \
                -H "Content-Type: application/json" \
                -d "{
                    \"model\": \"$MODEL\",
                    \"messages\": [{\"role\": \"user\", \"content\": \"Write a haiku about technology.\"}],
                    \"max_tokens\": 60
                }" > /dev/null 2>&1 &
            request_count=$((request_count + 1))
        done
        wait
        log_metric "Sent $request_count requests..."
        sleep 2
    done

    log_success "Test 4 complete - Sent $request_count requests. Check tokens/sec in Grafana"
}

# Test 5: Variable context lengths (measure KV cache utilization)
test_variable_context() {
    log_info "Test 5: Variable Context Lengths (testing KV cache utilization)..."

    # Short contexts
    for i in {1..10}; do
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}],
                \"max_tokens\": 20
            }" > /dev/null 2>&1 &
    done
    wait
    log_metric "Short contexts sent (10 requests)"
    sleep 2

    # Medium contexts
    local medium_context="Tell me about the following topic in detail: machine learning, neural networks, and deep learning."
    for i in {1..10}; do
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"$medium_context\"}],
                \"max_tokens\": 100
            }" > /dev/null 2>&1 &
    done
    wait
    log_metric "Medium contexts sent (10 requests)"
    sleep 2

    # Long contexts
    local long_context="Context: AI and ML are transforming technology. Deep learning uses neural networks with multiple layers. "
    long_context+="These systems learn from data through backpropagation and gradient descent. "
    long_context+="Common architectures include CNNs, RNNs, and Transformers. "
    long_context+="Question: Summarize the key concepts mentioned above."
    for i in {1..10}; do
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"$long_context\"}],
                \"max_tokens\": 120
            }" > /dev/null 2>&1 &
    done
    wait
    log_metric "Long contexts sent (10 requests)"

    log_success "Test 5 complete - Check KV cache utilization percentage"
}

# Get current metrics from a pod
get_current_metrics() {
    log_info "Fetching current metrics from vLLM pods..."

    local pod=$(kubectl get pods -n $NAMESPACE -l llm-d.ai/inferenceServing=true -o name | head -1)

    if [ -z "$pod" ]; then
        log_warn "No vLLM pods found!"
        return
    fi

    echo ""
    log_metric "Current Metrics from $pod:"
    echo "---------------------------------------------------"

    kubectl exec -n $NAMESPACE $pod -c vllm -- curl -s http://localhost:8200/metrics 2>&1 | \
        grep -E "vllm:kv_cache_usage_perc|vllm:num_requests|vllm:request_success|vllm:prompt_tokens|vllm:generation_tokens" | \
        grep -v "#" | grep -v "created" | while read -r line; do
        echo "  $line"
    done
    echo "---------------------------------------------------"
    echo ""
}

# Main benchmark execution
main() {
    log_info "====================================================="
    log_info "Alternative Metrics Benchmark for ARM64"
    log_info "====================================================="
    log_info "Gateway URL: $GATEWAY_URL"
    log_info "Model: $MODEL"
    log_info "Duration: ${DURATION}s"
    log_info ""
    log_warn "Note: KV cache hit/miss metrics are NOT available on ARM64"
    log_info "Focusing on: Latency, Throughput, Queue Depth, Load Balancing"
    log_info "====================================================="
    echo ""

    # Check if gateway is accessible
    if ! curl -s --max-time 5 "$GATEWAY_URL/v1/models" > /dev/null 2>&1; then
        log_warn "ERROR: Cannot reach gateway at $GATEWAY_URL"
        log_warn "Make sure port-forward is running:"
        log_warn "  kubectl port-forward -n $NAMESPACE svc/infra-cpu-inference-inference-gateway-istio 8000:80"
        exit 1
    fi

    log_success "Gateway is accessible ✓"
    echo ""

    # Show initial metrics
    get_current_metrics

    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local iteration=1

    while [ $(date +%s) -lt $end_time ]; do
        local remaining=$((end_time - $(date +%s)))
        log_info "═══════════════════════════════════════════════════"
        log_info "Iteration $iteration (${remaining}s remaining)"
        log_info "═══════════════════════════════════════════════════"
        echo ""

        # Run all test patterns
        test_baseline_latency
        sleep 5

        test_concurrent_load 15
        sleep 5

        test_burst_pattern
        sleep 5

        test_sustained_throughput 30
        sleep 5

        test_variable_context
        sleep 5

        # Show metrics after iteration
        get_current_metrics

        log_success "Iteration $iteration completed"
        echo ""

        iteration=$((iteration + 1))
    done

    log_success "====================================================="
    log_success "Benchmark Complete!"
    log_success "====================================================="
    log_info "Total time: ${DURATION}s"
    log_info "Total iterations: $((iteration - 1))"
    echo ""

    log_info "📊 View these metrics in Grafana:"
    log_info "   http://localhost:3000/d/llm-d-performance/"
    echo ""

    log_success "Available Metrics (ARM64 compatible):"
    echo "  ✅ KV Cache Usage Percentage (utilization)"
    echo "  ✅ Request Queue Depth (load balancing)"
    echo "  ✅ Time to First Token (TTFT)"
    echo "  ✅ End-to-End Request Latency"
    echo "  ✅ Requests Per Second"
    echo "  ✅ Tokens Per Second"
    echo "  ✅ Active Requests"
    echo ""

    log_warn "Unavailable Metrics (ARM64 limitation):"
    echo "  ❌ Cache Hit Rate (prefix caching not supported)"
    echo "  ❌ Cache Miss Rate (prefix caching not supported)"
    echo ""

    log_info "Check EPP routing decisions:"
    log_info "  kubectl logs -n $NAMESPACE -l inferencepool=gaie-cpu-inference-epp --tail=100"
    echo ""

    log_info "Check detailed vLLM metrics:"
    log_info "  kubectl get pods -n $NAMESPACE -l llm-d.ai/inferenceServing=true -o name | head -1 | \\"
    log_info "    xargs -I {} kubectl exec -n $NAMESPACE {} -c vllm -- \\"
    log_info "    curl -s http://localhost:8200/metrics | grep -E 'vllm:(time_to_first_token|e2e_request|num_requests)'"
}

# Run benchmark
main

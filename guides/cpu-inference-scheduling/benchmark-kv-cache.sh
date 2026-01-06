#!/usr/bin/env bash

#######################################
# KV Cache Routing Metrics Benchmark Script
#
# This script generates various request patterns to test KV cache routing
# and populate Grafana dashboard metrics for llm-d.
#
# Metrics tested:
# - KV cache hit rate
# - Prefix cache utilization
# - Request routing across replicas
# - Queue depth and load balancing
#
# Usage:
#   ./benchmark-kv-cache.sh [duration_seconds]
#
# Example:
#   ./benchmark-kv-cache.sh 60  # Run for 60 seconds
#######################################

set -euo pipefail

# Configuration
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8000}"
MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
DURATION="${1:-60}"  # Default 60 seconds
MAX_TOKENS=100
TEMPERATURE=0.7

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Test 1: Requests with shared prefixes (should trigger KV cache hits)
test_shared_prefixes() {
    local count=$1
    log_info "Test 1: Sending $count requests with SHARED prefixes (testing KV cache hits)..."

    local shared_prompt="You are a helpful AI assistant. Please help me understand"

    for i in $(seq 1 $count); do
        local question=$(shuf -n 1 -e \
            "what is machine learning?" \
            "how neural networks work?" \
            "the difference between AI and ML?" \
            "what is deep learning?" \
            "how transformers work?")

        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [
                    {\"role\": \"system\", \"content\": \"$shared_prompt\"},
                    {\"role\": \"user\", \"content\": \"$question\"}
                ],
                \"max_tokens\": $MAX_TOKENS,
                \"temperature\": $TEMPERATURE
            }" > /dev/null 2>&1 &

        # Small delay to spread requests
        sleep 0.1
    done

    wait
    log_success "Test 1 completed: $count requests with shared prefixes sent"
}

# Test 2: Requests with unique prefixes (should trigger cache misses)
test_unique_prefixes() {
    local count=$1
    log_info "Test 2: Sending $count requests with UNIQUE prefixes (testing cache misses)..."

    for i in $(seq 1 $count); do
        local unique_prompt="Request #$i-$(date +%s)-$RANDOM: Tell me about"
        local topic=$(shuf -n 1 -e \
            "quantum physics" \
            "ancient history" \
            "modern art" \
            "space exploration" \
            "marine biology")

        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"$unique_prompt $topic\"}],
                \"max_tokens\": $MAX_TOKENS,
                \"temperature\": $TEMPERATURE
            }" > /dev/null 2>&1 &

        sleep 0.1
    done

    wait
    log_success "Test 2 completed: $count requests with unique prefixes sent"
}

# Test 3: Burst requests (testing load balancing and queue depth)
test_burst_load() {
    local burst_size=$1
    log_info "Test 3: Sending BURST of $burst_size concurrent requests (testing load balancing)..."

    for i in $(seq 1 $burst_size); do
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 10 and explain each number.\"}],
                \"max_tokens\": 150,
                \"temperature\": 0.8
            }" > /dev/null 2>&1 &
    done

    wait
    log_success "Test 3 completed: Burst of $burst_size requests sent"
}

# Test 4: Repeated identical requests (maximum cache hits)
test_identical_requests() {
    local count=$1
    log_info "Test 4: Sending $count IDENTICAL requests (testing maximum cache hits)..."

    local identical_prompt="What is the capital of France?"

    for i in $(seq 1 $count); do
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"$identical_prompt\"}],
                \"max_tokens\": 50,
                \"temperature\": 0.0
            }" > /dev/null 2>&1 &

        sleep 0.05
    done

    wait
    log_success "Test 4 completed: $count identical requests sent"
}

# Test 5: Long context requests (testing KV cache capacity)
test_long_context() {
    local count=$1
    log_info "Test 5: Sending $count requests with LONG contexts (testing KV cache capacity)..."

    local long_context="This is a long context that will consume more KV cache space. "
    long_context+="We are testing how the system handles longer prompts and whether the KV cache "
    long_context+="can efficiently store and retrieve longer sequences. "
    long_context+="This helps us understand the performance characteristics of the inference system. "
    long_context+="Additional context: The model should be able to handle this efficiently. "

    for i in $(seq 1 $count); do
        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"$long_context Question $i: Summarize this in one sentence.\"}],
                \"max_tokens\": 100,
                \"temperature\": 0.7
            }" > /dev/null 2>&1 &

        sleep 0.2
    done

    wait
    log_success "Test 5 completed: $count long context requests sent"
}

# Test 6: Alternating patterns (testing cache eviction)
test_alternating_patterns() {
    local count=$1
    log_info "Test 6: Sending $count requests with ALTERNATING patterns (testing cache eviction)..."

    local pattern_a="Pattern A: Tell me about machine learning in"
    local pattern_b="Pattern B: Explain the concept of artificial intelligence in"

    for i in $(seq 1 $count); do
        if [ $((i % 2)) -eq 0 ]; then
            local prompt="$pattern_a simple terms"
        else
            local prompt="$pattern_b detail"
        fi

        curl -s "$GATEWAY_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$MODEL\",
                \"messages\": [{\"role\": \"user\", \"content\": \"$prompt\"}],
                \"max_tokens\": $MAX_TOKENS,
                \"temperature\": 0.7
            }" > /dev/null 2>&1 &

        sleep 0.1
    done

    wait
    log_success "Test 6 completed: $count alternating pattern requests sent"
}

# Main benchmark execution
main() {
    log_info "====================================================="
    log_info "KV Cache Routing Metrics Benchmark"
    log_info "====================================================="
    log_info "Gateway URL: $GATEWAY_URL"
    log_info "Model: $MODEL"
    log_info "Duration: ${DURATION}s"
    log_info "====================================================="
    echo ""

    # Check if gateway is accessible
    if ! curl -s --max-time 5 "$GATEWAY_URL/v1/models" > /dev/null 2>&1; then
        log_warn "ERROR: Cannot reach gateway at $GATEWAY_URL"
        log_warn "Make sure port-forward is running:"
        log_warn "  kubectl port-forward -n llm-d-cpu-inference svc/infra-cpu-inference-inference-gateway-istio 8000:80"
        exit 1
    fi

    log_success "Gateway is accessible ✓"
    echo ""

    local start_time=$(date +%s)
    local end_time=$((start_time + DURATION))
    local iteration=1

    while [ $(date +%s) -lt $end_time ]; do
        local remaining=$((end_time - $(date +%s)))
        log_info "Iteration $iteration (${remaining}s remaining)..."
        echo ""

        # Run all test patterns
        test_shared_prefixes 10
        sleep 2

        test_unique_prefixes 8
        sleep 2

        test_burst_load 15
        sleep 3

        test_identical_requests 12
        sleep 2

        test_long_context 6
        sleep 2

        test_alternating_patterns 10
        sleep 3

        echo ""
        log_success "Iteration $iteration completed"
        echo "-----------------------------------------------------"
        echo ""

        iteration=$((iteration + 1))
    done

    log_success "====================================================="
    log_success "Benchmark completed!"
    log_success "====================================================="
    log_info "Total time: ${DURATION}s"
    log_info "Total iterations: $((iteration - 1))"
    echo ""
    log_info "View metrics in Grafana:"
    log_info "  http://localhost:3000/d/llm-d-performance/"
    echo ""
    log_info "Check EPP routing decisions:"
    log_info "  kubectl logs -n llm-d-cpu-inference -l inferencepool=gaie-cpu-inference-epp --tail=100"
    echo ""
    log_info "Check vLLM metrics from pods:"
    log_info "  kubectl get pods -n llm-d-cpu-inference -l llm-d.ai/inferenceServing=true -o name | \\"
    log_info "    xargs -I {} kubectl exec -n llm-d-cpu-inference {} -c vllm -- curl -s http://localhost:8200/metrics | grep -E 'vllm_cache|vllm_request'"
}

# Run benchmark
main

#!/usr/bin/env bash

#######################################
# Quick KV Cache Benchmark (5 minutes)
#
# Fast benchmark to populate Grafana metrics
# Sends ~200 requests over 5 minutes
#######################################

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8000}"
MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"

echo "🚀 Starting 5-minute Quick Benchmark..."
echo "Gateway: $GATEWAY_URL"
echo ""

# Test 1: Shared prefix requests (60 requests)
echo "📊 Test 1/4: Shared prefix requests (60 requests)..."
for i in {1..60}; do
    curl -s "$GATEWAY_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a helpful assistant.\"},
                {\"role\": \"user\", \"content\": \"Explain topic $i in one sentence.\"}
            ],
            \"max_tokens\": 50
        }" | jq -r '.choices[0].message.content // "Error"' &

    if [ $((i % 10)) -eq 0 ]; then
        wait
        echo "  ✓ Sent $i/60 requests..."
        sleep 2
    fi
done
wait
echo "✅ Test 1 complete"
sleep 5

# Test 2: Identical requests (40 requests)
echo "📊 Test 2/4: Identical requests (40 requests)..."
for i in {1..40}; do
    curl -s "$GATEWAY_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2?\"}],
            \"max_tokens\": 20,
            \"temperature\": 0.0
        }" > /dev/null 2>&1 &

    if [ $((i % 10)) -eq 0 ]; then
        wait
        echo "  ✓ Sent $i/40 requests..."
        sleep 1
    fi
done
wait
echo "✅ Test 2 complete"
sleep 5

# Test 3: Burst load (50 requests)
echo "📊 Test 3/4: Burst load testing (50 requests)..."
for i in {1..50}; do
    curl -s "$GATEWAY_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Count from 1 to 5.\"}],
            \"max_tokens\": 100
        }" > /dev/null 2>&1 &

    # Send bursts of 10
    if [ $((i % 10)) -eq 0 ]; then
        echo "  ✓ Sent burst $((i/10))/5..."
        wait
        sleep 3
    fi
done
wait
echo "✅ Test 3 complete"
sleep 5

# Test 4: Long context requests (50 requests)
echo "📊 Test 4/4: Long context requests (50 requests)..."
LONG_CONTEXT="Context: This is a detailed explanation that includes multiple concepts. "
LONG_CONTEXT+="We are testing how the system handles longer prompts and KV cache utilization. "
LONG_CONTEXT+="This helps measure performance with various input lengths. "

for i in {1..50}; do
    curl -s "$GATEWAY_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": [{\"role\": \"user\", \"content\": \"$LONG_CONTEXT Question $i: Summarize.\"}],
            \"max_tokens\": 80
        }" > /dev/null 2>&1 &

    if [ $((i % 10)) -eq 0 ]; then
        wait
        echo "  ✓ Sent $i/50 requests..."
        sleep 2
    fi
done
wait
echo "✅ Test 4 complete"

echo ""
echo "🎉 Quick Benchmark Complete!"
echo ""
echo "📈 View metrics in Grafana:"
echo "   http://localhost:3000/d/llm-d-performance/llm-d-performance-dashboard"
echo ""
echo "🔍 Check vLLM metrics:"
echo "   kubectl get pods -n llm-d-cpu-inference -l llm-d.ai/inferenceServing=true -o name | head -1 | \\"
echo "     xargs -I {} kubectl exec -n llm-d-cpu-inference {} -c vllm -- \\"
echo "     curl -s http://localhost:8200/metrics | grep -E 'cache|queue|request'"

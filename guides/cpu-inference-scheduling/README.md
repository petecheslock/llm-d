# Guide: CPU Inference Scheduling on Apple Silicon

## ✅ Status: Fully Operational

**Last Updated**: December 17, 2025

This guide provides a **complete, working deployment** of llm-d intelligent inference scheduling using CPU-only vLLM on Apple Silicon (ARM64) Macs. All known issues have been resolved.

### What's Working ✅

- **Podman Machine**: 24GB RAM, 8 CPUs, 100GB disk - sized for 2 replica deployment
- **Kind Cluster**: Local Kubernetes with Gateway API and Istio
- **ARM64 Images**: Locally built routing sidecar and EPP for Apple Silicon
- **Prometheus Stack**: Full monitoring with ServiceMonitor/PodMonitor
- **2 vLLM Replicas**: Running Qwen2-0.5B-Instruct with 6Gi memory each
- **Intelligent Routing**: EPP load-aware and prefix-cache aware scheduling
- **HTTPRoute**: Gateway → InferencePool → vLLM backends
- **Inference Requests**: `/v1/chat/completions` and `/v1/models` fully functional
- **Metrics Collection**: Prometheus scraping vLLM metrics from both replicas

### Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  Podman Machine (24GB RAM, 8 CPUs)                           │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Kind Cluster (llm-d-cpu)                              │  │
│  │  ┌──────────────────────────────────────────────────┐  │  │
│  │  │  Namespace: llm-d-cpu-inference                   │  │  │
│  │  │                                                    │  │  │
│  │  │  ┌──────────────┐                                 │  │  │
│  │  │  │ Istio        │  :80                            │  │  │
│  │  │  │ Gateway      │────┐                            │  │  │
│  │  │  └──────────────┘    │                            │  │  │
│  │  │                      │ HTTPRoute                  │  │  │
│  │  │  ┌──────────────┐    │                            │  │  │
│  │  │  │ EPP          │◄───┘                            │  │  │
│  │  │  │ (Gateway API │  InferencePool                  │  │  │
│  │  │  │  Inference   │  Selector                       │  │  │
│  │  │  │  Extension)  │◄───────────────┐                │  │  │
│  │  │  └──────────────┘                │                │  │  │
│  │  │                                  │                │  │  │
│  │  │  ┌───────────────────────────┐  │                │  │  │
│  │  │  │ Model Service Pod 1       │  │                │  │  │
│  │  │  │ ┌──────────────────────┐  │  │                │  │  │
│  │  │  │ │ routing-proxy        │  │  │                │  │  │
│  │  │  │ │ (sidecar)            │  │  │                │  │  │
│  │  │  │ └──────────────────────┘  │  │                │  │  │
│  │  │  │ ┌──────────────────────┐  │  │ Labels:        │  │  │
│  │  │  │ │ vLLM Container       │  │  │ llm-d.ai/      │  │  │
│  │  │  │ │ - Qwen2-0.5B        │◄─┼──┘ inferenceServing│  │  │
│  │  │  │ │ - CPU mode           │  │    = "true"       │  │  │
│  │  │  │ │ - 6Gi memory         │  │                   │  │  │
│  │  │  │ │ - 3 CPUs             │  │                   │  │  │
│  │  │  │ │ - Port 8200          │  │                   │  │  │
│  │  │  │ └──────────────────────┘  │                   │  │  │
│  │  │  └───────────────────────────┘                   │  │  │
│  │  │                                                   │  │  │
│  │  │  ┌───────────────────────────┐                   │  │  │
│  │  │  │ Model Service Pod 2       │                   │  │  │
│  │  │  │ ┌──────────────────────┐  │                   │  │  │
│  │  │  │ │ routing-proxy        │  │                   │  │  │
│  │  │  │ │ (sidecar)            │  │                   │  │  │
│  │  │  │ └──────────────────────┘  │                   │  │  │
│  │  │  │ ┌──────────────────────┐  │                   │  │  │
│  │  │  │ │ vLLM Container       │  │                   │  │  │
│  │  │  │ │ - Qwen2-0.5B        │◄─┼───────────────────┘  │  │
│  │  │  │ │ - CPU mode           │  │                      │  │
│  │  │  │ │ - 6Gi memory         │  │                      │  │
│  │  │  │ │ - 3 CPUs             │  │                      │  │
│  │  │  │ │ - Port 8200          │  │                      │  │
│  │  │  │ └──────────────────────┘  │                      │  │
│  │  │  └───────────────────────────┘                      │  │
│  │  │                                                      │  │
│  │  │  ┌──────────────────────────────────┐               │  │
│  │  │  │ Prometheus + Grafana             │               │  │
│  │  │  │ (llm-d-monitoring namespace)     │               │  │
│  │  │  └──────────────────────────────────┘               │  │
│  │  └──────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## Hardware Requirements

**Minimum Requirements** (for this guide):
- **Apple Silicon Mac** (M1/M2/M3/M4 series)
- **24GB RAM** (for podman machine running 2 replicas × 6Gi)
- **100GB free disk space** (for podman machine, images, and models)
- **8 CPU cores** (for 2 replicas × 3 CPUs each)

**Tested Configuration**:
- MacBook with 36GB RAM
- Podman machine: 24GB RAM, 8 CPUs, 100GB disk
- 2 vLLM decode replicas running Qwen2-0.5B-Instruct

## Quick Start

Use the automated deployment script:

```bash
# Deploy everything (podman, kind, images, helm charts)
./deploy.sh

# Tear down everything (prompts for confirmation before deleting podman machine/images)
./deploy.sh --teardown

# Tear down non-interactively (keeps podman machine and images for faster redeployment)
./deploy.sh --teardown --non-interactive
```

The script handles:
- ✅ Podman machine setup with resource validation (24GB RAM, 8 CPUs, 100GB disk)
- ✅ Kind cluster deployment with experimental podman provider
- ✅ Gateway API CRDs and GAIE CRDs installation
- ✅ Istio installation via helmfile
- ✅ Prometheus + Grafana stack with datasource configuration
- ✅ Building ARM64 images locally (routing sidecar from main branch, EPP from v1.2.0-rc.1 tag)
- ✅ Pulling vLLM macOS image (ARM64-compatible)
- ✅ Loading all images into kind cluster
- ✅ Deploying all Helm charts (infra, GAIE InferencePool, model service)
- ✅ Creating HTTPRoute for request routing
- ✅ Waiting for pods with proper label selectors
- ✅ Port-forwarding gateway for testing
- ✅ Automated inference testing

For manual deployment steps, see [Manual Deployment](#manual-deployment) below.

### Script Features

The `deploy.sh` script includes:

**Resource Management:**
- Validates existing podman machine configuration (memory, CPU, disk)
- Only recreates machine if disk size differs (disk cannot be resized)
- Updates memory/CPU if needed without recreating

**Interactive vs Non-Interactive Teardown:**
- `./deploy.sh --teardown` - Interactive mode, prompts before deleting podman machine and images
- `./deploy.sh --teardown --non-interactive` - Non-interactive mode, keeps machine and images for faster redeployment

**Image Building:**
- Routing sidecar: builds from `main` branch (v0.4.0-rc.1 tag doesn't exist in git)
- EPP: builds from `v1.2.0-rc.1` tag with simple Dockerfile patch (`GOARCH=arm64`)
- All images built with `--platform=linux/arm64` for Apple Silicon

**Validation and Testing:**
- Checks for required tools before starting
- Waits for pods using correct label selectors (`llm-d.ai/inferenceServing=true`)
- Automatically tests deployment with inference request
- Displays helpful next steps on completion

## Testing the Deployment

Once deployed, test inference requests:

```bash
# List available models
curl -s http://localhost:8000/v1/models | jq

# Chat completion request
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2-0.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain LLM inference in one sentence."}],
    "max_tokens": 50,
    "temperature": 0.7
  }' | jq -r '.choices[0].message.content'
```

### Monitor Routing Behavior

Send multiple requests and watch EPP route between 2 replicas:

```bash
# Send 10 requests
for i in {1..10}; do
  echo "Request $i:"
  curl -s http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "Qwen/Qwen2-0.5B-Instruct", "messages": [{"role": "user", "content": "Count to 3"}], "max_tokens": 20}' \
    | jq -r '.choices[0].message.content'
done

# Check EPP logs for routing decisions
kubectl logs -n llm-d-cpu-inference -l inferencepool=gaie-cpu-inference-epp --tail=50
```

### Access Monitoring

The deployment includes the [Monitoring stack](../../docs/monitoring/README.md) with Prometheus and Grafana.

Access the UIs:

```bash
# Prometheus
kubectl port-forward -n llm-d-monitoring svc/llmd-kube-prometheus-stack-prometheus 9090:9090
# Visit http://localhost:9090

# Grafana (admin/admin)
kubectl port-forward -n llm-d-monitoring svc/llmd-grafana 3000:80
# Visit http://localhost:3000
```

Pre-loaded dashboards including the **LLM-D CPU Performance Dashboard** will be available in Grafana.

## Key Technical Learnings

### Why This Configuration Works

This deployment succeeds where previous attempts failed due to these critical factors:

#### 1. Sufficient Podman Machine Resources

**Problem**: Initial 8GB RAM was insufficient for 2 replicas
**Solution**: 24GB RAM allows 2 × 6Gi replicas + Kubernetes overhead

```bash
# Working configuration
# Note: disk-size cannot be changed with 'set' - requires machine recreation
podman machine init --memory 24576 --cpus 8 --disk-size 100

# To update existing machine (memory/cpus only):
podman machine set --memory 24576 --cpus 8
```

#### 2. Adequate Startup Probe Timeout

**Problem**: vLLM compilation on CPU takes 3-5 minutes
**Solution**: 300s initial delay allows compilation to complete

```yaml
startupProbe:
  httpGet:
    path: /health
    port: 8200
  initialDelaySeconds: 300  # 5 minutes - critical for CPU compilation
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 80
```

#### 3. Named Metrics Port for PodMonitor

**Problem**: PodMonitor couldn't scrape metrics without named port
**Solution**: Named the container port "metrics"

```yaml
ports:
  - containerPort: 8200
    name: metrics  # Required for PodMonitor portName reference
    protocol: TCP

monitoring:
  podmonitor:
    enabled: true
    portName: "metrics"  # Matches the named port above
```

#### 4. HTTPRoute Manual Installation

**Problem**: Requests to gateway returned no response
**Solution**: HTTPRoute must be applied manually after Helm charts

This is the standard pattern from the [inference-scheduling guide](../inference-scheduling/README.md#install-httproute-when-using-gateway-option) - HTTPRoute is not created by Helm charts and must be applied separately.

```bash
kubectl apply -f httproute.yaml -n llm-d-cpu-inference
```

#### 5. Correct Model with API Support

**Problem**: facebook/opt-125m didn't support chat completion endpoint
**Solution**: Switched to Qwen2-0.5B-Instruct (instruction-tuned model)

```yaml
modelArtifacts:
  uri: "hf://Qwen/Qwen2-0.5B-Instruct"
  size: 2Gi
  name: "Qwen/Qwen2-0.5B-Instruct"
```

With `--max-model-len 2048` to fit in memory constraints.

#### 6. Simple ARM64 EPP Build

**Problem**: Complex Dockerfile patching with ARG TARGETARCH caused Go 1.24 runtime bugs (`lfstack.push` crashes)
**Solution**: Simple sed replacement works perfectly

```bash
# The working approach - just change GOARCH directly
sed -i.bak 's/ENV GOARCH=amd64/ENV GOARCH=arm64/' Dockerfile
podman build --platform=linux/arm64 -t localhost/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64 .
```

**Why this works**: The Dockerfile already has `ARG TARGETARCH` but wasn't using it correctly. Rather than fix the complex build argument propagation, directly setting `GOARCH=arm64` produces a clean native ARM64 binary that runs without crashes.

#### 7. Correct Pod Label Selectors

**Problem**: Waiting for pods with `app.kubernetes.io/name=llm-d-modelservice` found nothing
**Solution**: Model service pods use `llm-d.ai/inferenceServing=true`

```bash
# Correct label selector
kubectl get pods -n llm-d-cpu-inference -l llm-d.ai/inferenceServing=true
```

#### 8. Building from Correct Git References

**Routing Sidecar**:
- Git doesn't have v0.4.0-rc.1 tag (only in container registry)
- Build from `main` branch and tag as v0.4.0-rc.1-arm64

**EPP**:
- Git has v1.2.0-rc.1 tag
- Build from tag: `git checkout v1.2.0-rc.1`

## Manual Deployment

If you prefer to run steps manually instead of using the script:

### 1. Prerequisites

Install required tools:

```bash
# Install Homebrew if needed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install tools
brew install podman kubectl helm helmfile yq kind jq
```

### 2. Create Podman Machine

```bash
# Initialize podman machine with sufficient resources
podman machine init --cpus 8 --memory 24576 --disk-size 100

# Start podman machine
podman machine start

# Verify
podman info | grep -E "memTotal|cpus"
```

### 3. Create Kind Cluster

```bash
# Create cluster
kind create cluster --name llm-d-cpu

# Verify
kubectl cluster-info
kubectl get nodes
```

### 4. Install Prerequisites

#### Gateway API CRDs

```bash
# From the llm-d repository root
cd guides/prereq/gateway-provider
./install-gateway-provider-dependencies.sh
```

#### Istio

```bash
# From the llm-d repository root
cd guides/prereq/gateway-provider
helmfile sync -f istio.helmfile.yaml

# Verify
kubectl get pods -n istio-system
```

#### Prometheus Stack

```bash
# From the llm-d repository root
./docs/monitoring/scripts/install-prometheus-grafana.sh

# Verify
kubectl get pods -n llm-d-monitoring
```

### 5. Build ARM64 Images

#### Build Routing Sidecar

```bash
cd /tmp
git clone https://github.com/llm-d/llm-d-routing-sidecar.git
cd llm-d-routing-sidecar

# Use main branch (v0.4.0-rc.1 tag doesn't exist in git)
git checkout main

# Build ARM64 image
podman build --platform=linux/arm64 \
  -t localhost/llm-d-routing-sidecar:v0.4.0-rc.1-arm64 .
```

#### Build EPP

```bash
cd /tmp
git clone https://github.com/kubernetes-sigs/gateway-api-inference-extension.git
cd gateway-api-inference-extension

# Checkout v1.2.0-rc.1 release tag
git checkout v1.2.0-rc.1

# Patch Dockerfile for ARM64 build
# Simply change GOARCH from amd64 to arm64
# Note: macOS sed requires '' after -i, Linux does not
sed -i.bak 's/ENV GOARCH=amd64/ENV GOARCH=arm64/' Dockerfile

# Build ARM64 image
podman build --platform=linux/arm64 \
  -t localhost/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64 .
```

#### Pull vLLM macOS Image

```bash
podman pull quay.io/rh_ee_micyang/vllm-service:macos
```

### 6. Load Images into Kind

```bash
# Save images to tar files
podman save localhost/llm-d-routing-sidecar:v0.4.0-rc.1-arm64 \
  -o /tmp/routing-sidecar-arm64.tar

podman save localhost/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64 \
  -o /tmp/epp-arm64.tar

podman save quay.io/rh_ee_micyang/vllm-service:macos \
  -o /tmp/vllm-macos.tar

# Load into kind cluster
kind load image-archive /tmp/routing-sidecar-arm64.tar --name llm-d-cpu
kind load image-archive /tmp/epp-arm64.tar --name llm-d-cpu
kind load image-archive /tmp/vllm-macos.tar --name llm-d-cpu

# Verify
podman exec llm-d-cpu-control-plane crictl images | grep -E "routing-sidecar|epp|vllm"
```

### 7. Deploy Helm Charts

```bash
# From the llm-d repository root
cd guides/cpu-inference-scheduling

# Create namespace
export NAMESPACE=llm-d-cpu-inference
kubectl create namespace ${NAMESPACE}

# Deploy with helmfile
helmfile sync -n ${NAMESPACE}

# Verify
helm list -n ${NAMESPACE}
kubectl get pods -n ${NAMESPACE}
```

### 8. Install HTTPRoute

```bash
kubectl apply -f httproute.yaml -n ${NAMESPACE}

# Verify
kubectl get httproute -n ${NAMESPACE}
```

### 9. Wait for Pods to Start

The vLLM pods take ~5 minutes to start due to model loading and compilation:

```bash
# Watch pod status
kubectl get pods -n ${NAMESPACE} -w

# Watch vLLM logs (in another terminal)
kubectl logs -n ${NAMESPACE} -l llm-d.ai/inferenceServing=true -c vllm -f
```

Wait for both pods to reach `2/2 Running` status.

### 10. Port Forward Gateway

```bash
kubectl port-forward -n ${NAMESPACE} \
  svc/infra-cpu-inference-inference-gateway-istio 8000:80 &
```

Now test with curl (see [Testing the Deployment](#testing-the-deployment)).

## Configuration Details

### Model Configuration

Using **Qwen2-0.5B-Instruct** (0.5B parameters, ~2GB):
- Instruction-tuned for chat/completion tasks
- Supports `/v1/chat/completions` endpoint
- Public model (no HuggingFace token required)
- Small enough for 6Gi memory limit with 2GB KV cache

Key vLLM parameters:
```bash
--model Qwen/Qwen2-0.5B-Instruct
--max-model-len 2048  # Reduced from default 32768 to fit in memory
--dtype bfloat16
--disable-frontend-multiprocessing
```

### Resource Allocation

**Per Pod** (2 replicas):
```yaml
resources:
  limits:
    memory: 6Gi   # Model (2Gi) + KV cache (2Gi) + overhead (2Gi)
    cpu: "3"      # 3 CPUs per pod
  requests:
    cpu: "500m"   # Minimal for scheduling
    memory: 1Gi   # Minimal for scheduling
```

**Total Resources** (2 replicas):
- Memory: 12Gi (2 × 6Gi)
- CPU: 6 cores (2 × 3)
- Fits comfortably in 24GB podman machine with 8 CPUs

### Environment Variables

Critical vLLM CPU configuration:
```yaml
env:
  - name: VLLM_TARGET_DEVICE
    value: "cpu"
  - name: VLLM_PLATFORM
    value: "cpu"
  - name: CUDA_VISIBLE_DEVICES
    value: ""
  - name: VLLM_PORT
    value: "8200"
  - name: VLLM_CPU_NUM_OF_RESERVED_CPU
    value: "1"
  - name: VLLM_CPU_KVCACHE_SPACE
    value: "2"  # 2GB KV cache
```

## File Structure

```
cpu-inference-scheduling/
├── README.md                           # This file
├── deploy.sh                           # Automated deployment script
├── helmfile.yaml                       # Helm orchestration
├── httproute.yaml                      # Gateway routing configuration
├── gaie-inference-scheduling/
│   └── values.yaml                    # EPP config with ARM64 image
└── ms-inference-scheduling/
    └── values.yaml                    # Model service config with Qwen2-0.5B
```

## Troubleshooting

### Pods Stuck at 1/2 Running

**Symptom**: Model service pods show `1/2 Running` for >5 minutes

**Likely Cause**: vLLM compilation taking longer than expected

**Solution**:
```bash
# Check logs for compilation progress
kubectl logs -n llm-d-cpu-inference \
  -l llm-d.ai/inferenceServing=true -c vllm --tail=50

# Wait up to 10 minutes - compilation can be slow on CPU
```

### OOMKilled Errors

**Symptom**: Pod events show `OOMKilled`

**Likely Cause**: Insufficient memory in podman machine

**Solution**:
```bash
# Stop podman machine
podman machine stop

# Increase memory (requires recreating cluster)
podman machine set --memory 32768

# Start podman machine
podman machine start

# Recreate kind cluster and redeploy
kind delete cluster --name llm-d-cpu
kind create cluster --name llm-d-cpu
# ... reinstall prerequisites and redeploy
```

### No Response from Gateway

**Symptom**: `curl http://localhost:8000/v1/models` returns nothing

**Likely Causes**:
1. HTTPRoute not applied
2. Port forward not running
3. Pods not ready

**Solution**:
```bash
# Check HTTPRoute exists
kubectl get httproute -n llm-d-cpu-inference

# If missing, apply it
kubectl apply -f httproute.yaml -n llm-d-cpu-inference

# Check port forward is running
ps aux | grep "kubectl port-forward"

# If not running
kubectl port-forward -n llm-d-cpu-inference \
  svc/infra-cpu-inference-inference-gateway-istio 8000:80 &

# Check pods are ready
kubectl get pods -n llm-d-cpu-inference
```

### Prometheus Can't Scrape Metrics

**Symptom**: No vLLM metrics in Prometheus

**Likely Cause**: Container port not named "metrics"

**Solution**: Verify port name in values.yaml:
```yaml
ports:
  - containerPort: 8200
    name: metrics  # Must be named
    protocol: TCP
```

## Cleanup

### Quick Cleanup (Script)

```bash
cd guides/cpu-inference-scheduling

# Interactive teardown (prompts before deleting podman machine/images)
./deploy.sh --teardown

# Non-interactive teardown (keeps podman machine and images)
./deploy.sh --teardown --non-interactive
```

### Manual Cleanup

```bash
# Remove Helm deployments
cd guides/cpu-inference-scheduling
helmfile destroy -n llm-d-cpu-inference

# Remove HTTPRoute
kubectl delete -f httproute.yaml -n llm-d-cpu-inference

# Delete namespace
kubectl delete namespace llm-d-cpu-inference

# Delete kind cluster
kind delete cluster --name llm-d-cpu

# Stop and remove podman machine (reclaims 100GB disk)
podman machine stop
podman machine rm -f podman-machine-default

# Remove local images
podman rmi localhost/llm-d-routing-sidecar:v0.4.0-rc.1-arm64
podman rmi localhost/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64
podman rmi quay.io/rh_ee_micyang/vllm-service:macos
```

## Next Steps

Now that you have a working llm-d deployment:

1. **Explore Scheduling**: Send requests with different prompts and observe EPP routing decisions
2. **Monitor Metrics**: Check Prometheus for queue depth, KV cache utilization
3. **Experiment with Models**: Try other small models (< 3B parameters)
4. **Learn Architecture**: Study how EPP scores and selects backends
5. **Deploy to Production**: Use the [inference-scheduling guide](../inference-scheduling/README.md) for GPU deployments

## References

- [llm-d Documentation](https://www.llm-d.ai)
- [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
- [vLLM CPU Backend](https://docs.vllm.ai/en/latest/getting_started/cpu-installation.html)
- [Qwen2 Model](https://huggingface.co/Qwen/Qwen2-0.5B-Instruct)
- [Standard Inference Scheduling Guide](../inference-scheduling/README.md)

## License

Apache License 2.0

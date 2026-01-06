# Guide: CPU Inference Scheduling with Minikube

**Last Updated**: December 22, 2025

This guide provides a **complete, working deployment** of llm-d intelligent inference scheduling using Minikube with support for CPU, GPU, and Mac Metal acceleration. The deployment works on Apple Silicon, Intel Macs, and Linux systems.

### What's Working ✅

- **Minikube**: Cross-platform Kubernetes with 24GB RAM, 8 CPUs, 100GB disk
- **Multi-Platform Support**: Works on Apple Silicon, Intel Macs, and Linux
- **Container Runtime**: Supports both Docker and Podman drivers equally
- **GPU Support**: Optional GPU acceleration on Linux with NVIDIA Docker
- **Mac Metal**: Automatic acceleration on Apple Silicon
- **Gateway API & Istio**: Full service mesh with intelligent routing
- **ARM64 Images**: Pre-built images from Quay.io for Apple Silicon
- **Prometheus Stack**: Full monitoring with ServiceMonitor/PodMonitor
- **2 vLLM Replicas**: Running SmolLM2-360M-Instruct with 6Gi memory and 4 CPUs each
- **Intelligent Routing**: EPP load-aware and prefix-cache aware scheduling
- **HTTPRoute**: Gateway → InferencePool → vLLM backends
- **Inference Requests**: `/v1/chat/completions` and `/v1/models` fully functional
- **Metrics Collection**: Prometheus scraping vLLM metrics from both replicas

### Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  Minikube (24GB RAM, 8 CPUs, 100GB disk)                     │
│  Driver: Docker or Podman                                    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Kubernetes Cluster (llm-d-cpu)                        │  │
│  │  ┌──────────────────────────────────────────────────┐  │  │
│  │  │  Namespace: llm-d-cpu-inference                  │  │  │
│  │  │                                                  │  │  │
│  │  │  ┌──────────────┐                                │  │  │
│  │  │  │ Istio        │  :80                           │  │  │
│  │  │  │ Gateway      │────┐                           │  │  │
│  │  │  └──────────────┘    │                           │  │  │
│  │  │                      │ HTTPRoute                 │  │  │
│  │  │  ┌──────────────┐    │                           │  │  │
│  │  │  │ EPP          │◄───┘                           │  │  │
│  │  │  │ (Gateway API │  InferencePool                 │  │  │
│  │  │  │  Inference   │  Selector                      │  │  │
│  │  │  │  Extension)  │◄───────────────┐               │  │  │
│  │  │  └──────────────┘                │               │  │  │
│  │  │                                  │               │  │  │
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
│  │  │  │ │ - 8Gi memory         │  │                   │  │  │
│  │  │  │ │ - 4 CPUs             │  │                   │  │  │
│  │  │  │ │ - Port 8200          │  │                   │  │  │
│  │  │  │ └──────────────────────┘  │                   │  │  │
│  │  │  └───────────────────────────┘                   │  │  │
│  │  │                                                  │  │  │
│  │  │  ┌───────────────────────────┐                   │  │  │
│  │  │  │ Model Service Pod 2       │                   │  │  │
│  │  │  │ ┌──────────────────────┐  │                   │  │  │
│  │  │  │ │ routing-proxy        │  │                   │  │  │
│  │  │  │ │ (sidecar)            │  │                   │  │  │
│  │  │  │ └──────────────────────┘  │                   │  │  │
│  │  │  │ ┌──────────────────────┐  │                   │  │  │
│  │  │  │ │ vLLM Container       │  │                   │  │  │
│  │  │  │ │ - Qwen2-0.5B         │◄─┼───────────────────┘  │  │
│  │  │  │ │ - CPU mode           │  │                      │  │
│  │  │  │ │ - 8Gi memory         │  │                      │  │
│  │  │  │ │ - 4 CPUs             │  │                      │  │
│  │  │  │ │ - Port 8200          │  │                      │  │
│  │  │  │ └──────────────────────┘  │                      │  │
│  │  │  └───────────────────────────┘                      │  │
│  │  │                                                     │  │
│  │  │  ┌──────────────────────────────────┐               │  │
│  │  │  │ Prometheus + Grafana             │               │  │
│  │  │  │ (llm-d-monitoring namespace)     │               │  │
│  │  │  └──────────────────────────────────┘               │  │
│  │  └──────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

## Hardware Requirements

**Minimum Requirements**:
- **CPU**: 8+ cores for Docker driver, 10+ cores for Podman driver (Intel or Apple Silicon)
- **RAM**: 32GB+ total (24GB for Minikube + overhead)
  - **With Docker**: 24GB for Minikube (12Gi for 2 vLLM replicas + 8Gi for Istio/Prometheus/system + 4Gi overhead)
  - **With Podman**: 28GB for Podman machine (which hosts Minikube with 24GB)
- **Disk**: 100GB+ free space (120GB for Podman machine, for VM, images, and models)
- **OS**: macOS (10.13+) or Linux

**Platform-Specific Requirements**:

**Apple Silicon (M1/M2/M3/M4)**:
- **Container Runtime**: Docker Desktop 4.0+ or Podman
- **Recommendation**: Docker Desktop enables Mac Metal acceleration via Virtualization.framework
- Native ARM64 container support

**Intel Mac**:
- **Container Runtime**: Docker Desktop or Podman
- Both work equally well on Intel Macs
- Standard x86_64 containers

**Linux**:
- **Container Runtime**: Docker or Podman
- **With GPU** (optional): NVIDIA GPU with 8GB+ VRAM, NVIDIA Docker runtime, CUDA drivers

**Tested Configurations**:
- MacBook Pro (Apple Silicon, 36GB RAM): Minikube with Docker driver and Podman driver
- MacBook Pro (Intel, 32GB RAM): Minikube with Podman driver
- Linux workstation (NVIDIA GPU, 64GB RAM): Minikube with Docker driver + GPU

## Quick Start

### Prerequisites

**Container Images:** This deployment uses pre-built ARM64 images from Quay.io:
- `quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64`
- `quay.io/petecheslock/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64`
- `quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64`

These images must be available before deployment. If you need to build them yourself, see [Building Images](#pull-arm64-images-from-quayio).

### Option 1: Full Automated Deployment (Recommended)

Use the automated deployment script:

```bash
# Auto-detect platform and deploy everything
./deploy.sh

# Specify driver explicitly
./deploy.sh --driver docker    # Use Docker
./deploy.sh --driver podman    # Use Podman

# Enable GPU support (Linux only)
./deploy.sh --gpu

# Tear down everything (prompts for confirmation)
./deploy.sh --teardown

# Tear down non-interactively (stops cluster without deleting)
./deploy.sh --teardown --non-interactive

# Show all options
./deploy.sh --help
```

The script will:
- Auto-detect your platform (Apple Silicon, Intel Mac, or Linux)
- Install missing tools (kubectl, helm, helmfile, minikube, jq, yq)
- Create and configure Minikube cluster
- Install Gateway API, Istio, and Prometheus
- Pull images from Quay.io
- Deploy all Helm charts
- Configure routing and test the deployment

### Option 2: Build Images Yourself

If you want to build and push your own images to Quay:

```bash
# 1. Login to Quay.io
podman login quay.io

# 2. Build and push to your Quay account (automatically sets up Podman machine)
export QUAY_USERNAME=your-username  # Change this
./build-and-push-to-quay.sh

# 3. Update image references in values.yaml files
# Edit ms-inference-scheduling/values.yaml
# Edit gaie-inference-scheduling/values.yaml
# Change quay.io/petecheslock to quay.io/your-username

# 4. Deploy
./deploy.sh
```

**Note**: The build script automatically:
- Checks for required tools (podman, jq, git)
- Initializes Podman machine if needed (macOS only, with rootful mode)
- Starts Podman machine if stopped
- Builds all three container images (routing-sidecar, EPP, vLLM)
- Pushes to your Quay.io account

### Option 3: Test Container Locally First

Test the llm-d-cpu container locally before deploying to Kubernetes - see [Test a Container Locally](#test-a-container-locally-optional).

The script handles:
- ✅ Platform detection (Apple Silicon, Intel Mac, Linux)
- ✅ Minikube cluster setup with resource allocation (24GB RAM, 8 CPUs, 100GB disk)
- ✅ Container runtime auto-detection (prefers Podman if available, falls back to Docker)
- ✅ Driver selection (Podman or Docker - both fully supported)
- ✅ GPU support configuration (Linux with NVIDIA)
- ✅ Mac Metal acceleration (Apple Silicon with Docker Desktop only)
- ✅ Gateway API CRDs and GAIE CRDs installation
- ✅ Istio installation via helmfile
- ✅ Prometheus + Grafana stack with datasource configuration
- ✅ Verifying access to Quay.io images:
  - `quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64`
  - `quay.io/petecheslock/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64`
  - `quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64`
- ✅ Deploying all Helm charts (infra, GAIE InferencePool, model service)
- ✅ Creating HTTPRoute for request routing
- ✅ Waiting for pods with proper label selectors
- ✅ Port-forwarding gateway for testing
- ✅ Automated inference testing

For manual deployment steps, see [Manual Deployment](#manual-deployment) below.

### Script Features

The `deploy.sh` script includes:

**Platform Detection:**
- Auto-detects Apple Silicon, Intel Mac, or Linux
- Recommends appropriate Minikube driver (Docker or Podman)
- Automatically initializes and starts Podman machine on macOS if needed
- Detects NVIDIA GPU availability on Linux
- Configures Mac Metal acceleration automatically on Apple Silicon

**Resource Management:**
- Creates Minikube cluster with 24GB RAM, 8 CPUs, 100GB disk
- Reuses existing Minikube cluster if present
- Validates cluster configuration

**Driver Support:**
- **Docker**: Works on all platforms, enables Mac Metal on Apple Silicon
- **Podman**: Fully supported alternative, tested on Mac and Linux
- Auto-detection with manual override via `--driver`
- Both drivers are first-class options

**GPU Support (Linux):**
- Enable with `--gpu` flag
- Requires NVIDIA Docker runtime
- Automatically configures GPU passthrough to Minikube

**Interactive vs Non-Interactive Teardown:**
- `./deploy.sh --teardown` - Interactive mode, prompts before deleting cluster
- `./deploy.sh --teardown --non-interactive` - Non-interactive mode, stops cluster without deleting

**Image Management:**
- Verifies access to Quay.io images before deployment
- Minikube pulls images directly from registry (no local loading)
- Supports private registries with imagePullSecrets
- To build your own images, use `./build-and-push-to-quay.sh`

**Validation and Testing:**
- Checks for required tools before starting (auto-installs on Mac with Homebrew)
- Waits for pods using correct label selectors (`llm-d.ai/inferenceServing=true`)
- Automatically tests deployment with inference request
- Displays helpful next steps including Minikube dashboard access

## Testing the Deployment

Once deployed, test inference requests:

```bash
# List available models
curl -s http://localhost:8000/v1/models | jq

# Chat completion request
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "HuggingFaceTB/SmolLM2-360M-Instruct",
    "messages": [{"role": "user", "content": "Explain LLM inference in one sentence."}],
    "max_tokens": 50,
    "temperature": 0.7
  }' | jq -r '.choices[0].message.content'
```

### Monitor Routing Behavior

Send multiple requests to the vLLM replica:

```bash
# Send 10 requests
for i in {1..10}; do
  echo "Request $i:"
  curl -s http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "HuggingFaceTB/SmolLM2-360M-Instruct", "messages": [{"role": "user", "content": "Count to 3"}], "max_tokens": 20}' \
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

### Why Minikube?

**Advantages over kind**:
- ✅ **Cross-platform**: Consistent experience on Mac and Linux
- ✅ **Driver flexibility**: Works with Docker, Podman, or other drivers
- ✅ **GPU support**: Built-in NVIDIA GPU passthrough on Linux
- ✅ **Hardware acceleration**: Mac Metal support via Docker Desktop on Apple Silicon
- ✅ **Resource management**: Easy to configure CPU, memory, and disk
- ✅ **Dashboard**: Built-in Kubernetes dashboard (`minikube dashboard`)
- ✅ **Add-ons**: Rich ecosystem of add-ons for monitoring, ingress, etc.
- ✅ **Mature & stable**: Production-ready with extensive community support

### Why This Configuration Works

This deployment succeeds where previous attempts failed due to these critical factors:

#### 1. Sufficient Resources

**Problem**: Initial 8GB RAM was insufficient for replicas
**Solution**: 24GB RAM provides ample capacity for 2 replicas + Kubernetes overhead + headroom

```bash
# Minikube configuration
minikube start -p llm-d-cpu \
  --memory=24576 \
  --cpus=8 \
  --disk-size=100g \
  --driver=docker
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

**macOS:**
```bash
# Install Homebrew if needed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install tools
brew install kubectl helm helmfile minikube jq yq

# Install container runtime (choose one):
brew install --cask docker  # Docker Desktop (enables Mac Metal on Apple Silicon)
# OR
brew install podman          # Podman (fully supported alternative)
```

**Linux:**
```bash
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install Minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube

# Install helm, helmfile, jq, yq via package manager
# Example for Ubuntu/Debian:
sudo apt-get install -y jq

# Install container runtime (choose one):
# Docker: https://docs.docker.com/engine/install/
# OR
# Podman: sudo apt-get install -y podman (Ubuntu/Debian)
```

### 2. Start Minikube Cluster

**Basic setup (auto-detect driver):**
```bash
minikube start -p llm-d-cpu \
  --memory=24576 \
  --cpus=8 \
  --disk-size=100g

# Verify
kubectl cluster-info
kubectl get nodes
```

**With specific driver:**
```bash
# Docker driver
minikube start -p llm-d-cpu \
  --driver=docker \
  --memory=24576 \
  --cpus=8 \
  --disk-size=100g

# Podman driver
minikube start -p llm-d-cpu \
  --driver=podman \
  --memory=24576 \
  --cpus=8 \
  --disk-size=100g
```

**With GPU support (Linux only):**
```bash
minikube start -p llm-d-cpu \
  --driver=docker \
  --gpus all \
  --memory=24576 \
  --cpus=8 \
  --disk-size=100g

# Requires NVIDIA Docker runtime
# Follow: https://minikube.sigs.k8s.io/docs/tutorials/nvidia/
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

### 5. Pull ARM64 Images from Quay.io

The required images are pre-built and available on Quay.io:

```bash
# Pull all required images
podman pull quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64
podman pull quay.io/petecheslock/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64
podman pull quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64
```

> **Note:** These images are built from llm-d v0.4.0 release using `build-and-push-to-quay.sh`. The llm-d-cpu image uses vLLM commit c5f10cc139ec87e217f2bb56a677dd57394729f5 (v0.11.1+).

**Building Images Yourself (Optional):**

If you want to build and push your own images:

```bash
cd guides/cpu-inference-scheduling

# Login to Quay.io first
podman login quay.io

# Set your Quay username
export QUAY_USERNAME=your-username

# Build and push (takes 15-30 minutes for vLLM build)
# The script automatically sets up Podman machine on macOS
./build-and-push-to-quay.sh

# Make images public in Quay.io web UI or configure imagePullSecrets
```

The build script will:
- Check for required tools and install instructions if missing
- Initialize and start Podman machine (macOS only, in rootful mode)
- Build all three images (routing-sidecar, EPP, vLLM)
- Push to your Quay.io account

#### Test a Container Locally (Optional)

Test the llm-d-cpu container before deploying to Kubernetes:

```bash
# Run the container with Qwen2-0.5B-Instruct model
podman run -d \
  --name vllm-test \
  -p 8200:8200 \
  --entrypoint "" \
  -e VLLM_TARGET_DEVICE=cpu \
  -e VLLM_PLATFORM=cpu \
  -e CUDA_VISIBLE_DEVICES="" \
  -e VLLM_PORT=8200 \
  quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64 \
  /bin/bash -c "
    source /opt/venv/bin/activate && \
    python3 -m vllm.entrypoints.openai.api_server \
      --model Qwen/Qwen2-0.5B-Instruct \
      --host 0.0.0.0 \
      --port 8200 \
      --dtype bfloat16 \
      --max-model-len 2048 \
      --disable-frontend-multiprocessing
  "

# Follow the logs (takes 2-5 minutes for model download)
podman logs -f vllm-test

# Test endpoints (in another terminal)
curl -s http://localhost:8200/v1/models | jq
curl -s http://localhost:8200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen2-0.5B-Instruct", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 20}' | jq

# Clean up
podman stop vllm-test && podman rm vllm-test
```

### 6. Deploy with Helm

**No need to load images into Minikube** - the deployment will pull them directly from Quay.io.

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

Using **SmolLM2-360M-Instruct** (360M parameters, ~720MB model weights):
- Instruction-tuned for chat/completion tasks
- Supports `/v1/chat/completions` endpoint
- Public model (no HuggingFace token required)
- Efficient small model perfect for CPU inference demonstrations

Key vLLM parameters:
```bash
--model HuggingFaceTB/SmolLM2-360M-Instruct
--max-model-len 4096
--dtype bfloat16
--disable-frontend-multiprocessing
```

### Resource Allocation

**Per Pod** (per replica):
```yaml
resources:
  limits:
    memory: 6Gi   # Model (720MB) + loading overhead (800MB) + KV cache (100MB) + vLLM/PyTorch (~2.5Gi) + safety margin (~1.8Gi)
    cpu: "4"      # 4 CPUs per pod
  requests:
    cpu: "500m"   # Minimal for scheduling
    memory: 2Gi   # Sufficient for pod to start
```

**Memory Breakdown (per pod):**
- Model weights (bfloat16): ~720MB (360M params × 2 bytes)
- Model loading overhead: ~800MB
- KV cache: 100MB (--kv-cache-memory-bytes 104857600)
- vLLM runtime + PyTorch: ~2-2.5GB
- Safety margin: ~1.8-2.7GB
- **Total: 6Gi**

**Total Resources** (2 replicas):
- Memory: ~12Gi (6Gi per replica × 2)
- CPU: ~8 cores (4 per replica × 2)
- Fits comfortably in 24GB Minikube with 8 CPUs

### Environment Variables

Critical vLLM CPU configuration:
```yaml
env:
  - name: VLLM_TARGET_DEVICE
    value: "cpu"
  - name: VLLM_CPU_OMP_THREADS_BIND
    value: "auto"
# Note: KV cache is configured via --kv-cache-memory-bytes arg (100MB) instead of VLLM_CPU_KVCACHE_SPACE env var
```

## File Structure

```
cpu-inference-scheduling/
├── README.md                           # This file
├── deploy.sh                           # Automated deployment script (pulls from Quay)
├── build-and-push-to-quay.sh          # Build and push images to Quay.io
├── QUAY-WORKFLOW.md                   # Detailed Quay.io workflow guide
├── helmfile.yaml                       # Helm orchestration
├── httproute.yaml                      # Gateway routing configuration
├── gaie-inference-scheduling/
│   └── values.yaml                    # EPP config (Quay image reference)
└── ms-inference-scheduling/
    └── values.yaml                    # Model service config (Quay image reference)
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

**Symptom**: Pod events show `OOMKilled` or containers restart frequently

**Likely Causes**:
1. Insufficient memory limits for vLLM containers
2. Insufficient memory in Minikube VM
3. Too large KV cache allocation

**Check Memory Usage**:
```bash
# Check pod memory usage
kubectl top pods -n llm-d-cpu-inference

# Check pod events for OOM
kubectl get events -n llm-d-cpu-inference --sort-by='.lastTimestamp' | grep OOM

# Check container resource limits
kubectl get pods -n llm-d-cpu-inference -o json | \
  jq '.items[].spec.containers[] | select(.name=="vllm") | .resources'
```

**Solution 1: Increase Container Memory Limits**:
```yaml
# In ms-inference-scheduling/values.yaml
resources:
  limits:
    memory: 8Gi  # Increase from 6Gi if still seeing OOM
    cpu: "4"
  requests:
    memory: 3Gi  # Increase requests proportionally
```

**Solution 2: Increase Minikube Memory**:
```bash
# Delete and recreate with more memory
minikube delete -p llm-d-cpu
minikube start -p llm-d-cpu \
  --memory=32768 \  # Increase to 32GB
  --cpus=8 \
  --disk-size=100g

# Redeploy
./deploy.sh
```

**Solution 3: Reduce KV Cache**:
```yaml
# In ms-inference-scheduling/values.yaml
args:
  # Change --kv-cache-memory-bytes to a smaller value or 0
  - "--kv-cache-memory-bytes"
  - "52428800"  # Reduce to 50MB instead of 100MB
```

**Solution 4: Reduce to 1 Replica** (if testing):
```yaml
# In ms-inference-scheduling/values.yaml
decode:
  replicas: 1  # Reduce from 2 to 1
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

### InferencePool Not Found / HTTPRoute Backend Not Resolved

**Symptom**: Gateway returns HTTP 500 or no response, HTTPRoute status shows:
```
Message: backend(gaie-cpu-inference) not found
Reason: BackendNotFound
```
or
```
Message: referencing unsupported backendRef: group "inference.networking.x-k8s.io" kind "InferencePool"
Reason: InvalidKind
```

**Root Cause**: Istio's gateway controller only supports the stable `inference.networking.k8s.io/v1` API, not the experimental `inference.networking.x-k8s.io/v1alpha2` API. If the InferencePool was created with the wrong API version, Istio cannot resolve it.

**Solution**:

1. **Check which API group the InferencePool uses**:
```bash
# Check experimental API (v1alpha2)
kubectl get inferencepool.inference.networking.x-k8s.io -n llm-d-cpu-inference

# Check stable API (v1)
kubectl get inferencepool.inference.networking.k8s.io -n llm-d-cpu-inference
```

2. **If InferencePool only exists in x-k8s.io (experimental), create it in k8s.io (stable)**:
```bash
cat > /tmp/inferencepool-v1.yaml << 'EOF'
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: gaie-cpu-inference
  namespace: llm-d-cpu-inference
  labels:
    app.kubernetes.io/name: gaie-cpu-inference-epp
spec:
  selector:
    matchLabels:
      llm-d.ai/inferenceServing: "true"
  targetPorts:
    - number: 8000
  endpointPickerRef:
    name: gaie-cpu-inference-epp
    kind: Service
    port:
      number: 9002
    failureMode: FailClose
EOF
kubectl apply -f /tmp/inferencepool-v1.yaml
```

3. **Update HTTPRoute to use stable API** (if needed):
```bash
kubectl patch httproute llm-d-cpu-inference -n llm-d-cpu-inference \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/rules/0/backendRefs/0/group", "value":"inference.networking.k8s.io"}]'
```

4. **Verify HTTPRoute status**:
```bash
kubectl describe httproute llm-d-cpu-inference -n llm-d-cpu-inference
# Should show: "All references resolved" with Status: True
```

5. **Test the endpoint**:
```bash
curl -s http://localhost:8000/v1/models | jq
```

**Note**: The `values.yaml` file has been updated to use `inference.networking.k8s.io/v1` to prevent this issue in future deployments.

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

# Interactive teardown (prompts before deleting cluster)
./deploy.sh --teardown

# Non-interactive teardown (stops cluster without deleting)
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

# Delete Minikube cluster (reclaims disk space)
minikube delete -p llm-d-cpu

# OR just stop cluster (keeps VM for faster restart)
minikube stop -p llm-d-cpu
```

## Platform-Specific Configuration

### Container Runtime Comparison

**Podman:**
- ✅ Daemonless architecture (no background service)
- ✅ Rootless containers by default
- ✅ Compatible with Docker CLI commands
- ✅ Works on Mac (with Podman machine) and Linux
- ✅ Free and open source
- **Tested**: Fully tested with this guide on Apple Silicon and Linux

**Docker:**
- ✅ Widely used and well-documented
- ✅ Mac Metal acceleration on Apple Silicon (via Docker Desktop)
- ✅ Rich ecosystem of tools and integrations
- ✅ Works on Mac and Linux
- **Note**: Docker Desktop requires license for commercial use

### Mac Metal Acceleration (Apple Silicon + Docker)

**Only available with Docker Desktop:**
When using Docker Desktop on Apple Silicon Macs, Mac Metal acceleration is automatically enabled through the macOS Virtualization framework.

```bash
# Use Docker driver to enable Mac Metal
./deploy.sh --driver docker
```

**Benefits of Mac Metal:**
- Hardware-accelerated virtualization via Virtualization.framework
- Better performance than QEMU/KVM emulation
- Native ARM64 container support
- Efficient memory management

**Verify Metal is active:**
```bash
# Check Docker Desktop is using Mac Virtualization
docker info | grep -i "Operating System"

# Should show macOS version with Virtualization.framework
```

**Note**: Podman on Mac does not use Mac Metal, but is still a fully supported option.

### Using Podman

**Podman Machine (Mac only):**

On macOS, Podman requires a Linux VM (Podman machine). The deploy script automatically detects if a Podman machine exists and initializes/starts it if needed.

**Important Requirements**:
1. **Rootful mode**: Required for Kubernetes to set resource limits (rlimits)
2. **Sufficient resources**: The Podman machine must have more resources than Minikube requires:
   - **Minikube needs**: 8 CPUs, 24GB RAM
   - **Podman machine needs**: 10+ CPUs, 28+ GB RAM (to host Minikube)
3. **cgroup v2**: Podman libkrun uses cgroup v2 unified hierarchy (automatically configured)

```bash
# Script automatically handles Podman machine setup with proper resources and rootful mode
./deploy.sh --driver podman

# Or manually manage Podman machine
podman machine init --cpus 10 --memory 28672 --disk-size 120 --rootful
podman machine start

# Then start Minikube with Podman
minikube start -p llm-d-cpu --driver=podman --memory=24576 --cpus=8 \
  --extra-config=kubelet.cgroup-driver=systemd \
  --extra-config=kubeadm.ignore-preflight-errors=SystemVerification
```

**Podman on Linux:**

On Linux, Podman runs natively without a VM, providing better performance:

```bash
# Native Podman on Linux
./deploy.sh --driver podman
```

**Podman Commands:**

The script automatically detects and uses Podman commands when Podman driver is selected:

```bash
# Image verification uses podman
podman manifest inspect quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64

# Login to Quay (if needed for private images)
podman login quay.io
```

**Troubleshooting Podman:**

```bash
# Check Podman version
podman --version

# Check Podman machine status (Mac only)
podman machine list

# Verify rootful mode is enabled
podman machine inspect | grep -i rootful

# Initialize Podman machine if missing (Mac only) - MUST use --rootful
podman machine init --cpus 10 --memory 28672 --disk-size 120 --rootful

# Start Podman machine (Mac only)
podman machine start

# Switch existing machine to rootful mode (Mac only)
podman machine stop
podman machine set --rootful
podman machine start

# Restart Podman machine if having issues (Mac only)
podman machine stop
podman machine start

# Remove and recreate Podman machine (Mac only)
podman machine rm -f
podman machine init --cpus 10 --memory 28672 --disk-size 120 --rootful
podman machine start
```

**Common Issues**:

1. **rlimits permission errors**: Podman machine must be in rootful mode
   ```bash
   podman machine set --rootful  # After stopping the machine
   ```

2. **cpuset cgroup missing**: The cgroup exists in cgroup v2, but Kubernetes looks for it in the wrong place. This is handled by `--extra-config=kubeadm.ignore-preflight-errors=SystemVerification`

3. **Insufficient resources**: Podman machine needs 10+ CPUs and 28GB+ RAM to host Minikube

**Note**: The deploy script automatically handles Podman machine initialization with proper configuration on macOS, so manual intervention is usually not needed.

### GPU Support (Linux)

**Requirements:**
- NVIDIA GPU with 8GB+ VRAM
- NVIDIA drivers installed
- NVIDIA Docker runtime configured

**Setup:**

1. **Install NVIDIA Container Runtime:**
```bash
# Add NVIDIA repository
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

# Install
sudo apt-get update
sudo apt-get install -y nvidia-container-runtime

# Configure Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

2. **Deploy with GPU:**
```bash
# Automatic setup with script
./deploy.sh --gpu

# Manual Minikube setup
minikube start -p llm-d-cpu \
  --driver=docker \
  --gpus all \
  --memory=24576 \
  --cpus=8 \
  --disk-size=100g
```

3. **Update values.yaml for GPU workloads:**
```yaml
# In ms-inference-scheduling/values.yaml
decode:
  containers:
  - name: "vllm"
    image: quay.io/petecheslock/llm-d-gpu:v0.4.0  # GPU image
    env:
      - name: VLLM_TARGET_DEVICE
        value: "cuda"  # Change from "cpu"
    resources:
      limits:
        nvidia.com/gpu: 1  # Request GPU
```

**Verify GPU access:**
```bash
# Check GPU is visible in Minikube
minikube ssh -p llm-d-cpu -- nvidia-smi

# Should show GPU details
```

### Multi-Architecture Images

**Current Support:**
- ARM64 (Apple Silicon): `quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64`
- AMD64 (Intel/Linux): Build your own or use multi-arch manifest

**Building Multi-Arch Images:**
```bash
# Use buildx to create multi-arch images
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t quay.io/youruser/llm-d-cpu:v0.4.0 \
  --push .
```

## Next Steps

Now that you have a working llm-d deployment:

1. **Explore Scheduling**: Send requests with different prompts and observe EPP routing decisions
2. **Monitor Metrics**: Check Prometheus for queue depth, KV cache utilization
3. **Experiment with Models**: Try other small models (< 3B parameters)
4. **Try GPU Acceleration**: Deploy on Linux with NVIDIA GPU for faster inference
5. **Learn Architecture**: Study how EPP scores and selects backends
6. **Deploy to Production**: Use the [inference-scheduling guide](../inference-scheduling/README.md) for production GPU deployments
7. **Explore Minikube**: Use `minikube dashboard -p llm-d-cpu` to explore the Kubernetes dashboard

## References

- [llm-d Documentation](https://www.llm-d.ai)
- [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
- [vLLM CPU Backend](https://docs.vllm.ai/en/latest/getting_started/cpu-installation.html)
- [Qwen2 Model](https://huggingface.co/Qwen/Qwen2-0.5B-Instruct)
- [Standard Inference Scheduling Guide](../inference-scheduling/README.md)

## License

Apache License 2.0

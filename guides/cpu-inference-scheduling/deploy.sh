#!/usr/bin/env bash

#######################################
# llm-d CPU Inference Scheduling Deployment Script
#
# This script automates the complete deployment of llm-d intelligent
# inference scheduling on Apple Silicon using CPU-only vLLM.
#
# Usage:
#   ./deploy.sh           # Deploy everything
#   ./deploy.sh --teardown # Remove everything
#
# Requirements:
#   - Apple Silicon Mac (M1/M2/M3/M4)
#   - 24GB+ RAM available for podman machine
#   - 100GB+ free disk space
#   - Homebrew installed
#######################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PODMAN_MACHINE_NAME="podman-machine-default"
PODMAN_MEMORY="24576"  # 24GB
PODMAN_CPUS="8"
PODMAN_DISK="100"      # 100GB
KIND_CLUSTER_NAME="llm-d-cpu"
NAMESPACE="llm-d-cpu-inference"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUIDE_DIR="${REPO_ROOT}/guides/cpu-inference-scheduling"

# Temporary build directories
BUILD_DIR="/tmp/llm-d-build-$$"
ROUTING_SIDECAR_REPO="${BUILD_DIR}/llm-d-routing-sidecar"
EPP_REPO="${BUILD_DIR}/gateway-api-inference-extension"

# Image names
ROUTING_SIDECAR_IMAGE="localhost/llm-d-routing-sidecar:v0.4.0-rc.1-arm64"
EPP_IMAGE="localhost/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64"
VLLM_IMAGE="quay.io/rh_ee_micyang/vllm-service:macos"

# Image tar files
ROUTING_SIDECAR_TAR="/tmp/routing-sidecar-arm64.tar"
EPP_TAR="/tmp/epp-arm64.tar"
VLLM_TAR="/tmp/vllm-macos.tar"

#######################################
# Helper Functions
#######################################

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Required command not found: $1"
        return 1
    fi
    return 0
}

wait_for_pods() {
    local namespace=$1
    local label=$2
    local expected_count=$3
    local timeout=${4:-600}  # 10 minutes default

    log_info "Waiting for $expected_count pod(s) with label $label in namespace $namespace (timeout: ${timeout}s)..."

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local ready_count=$(kubectl get pods -n "$namespace" -l "$label" -o json 2>/dev/null | \
            jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo "0")

        if [ "$ready_count" -eq "$expected_count" ]; then
            log_success "All $expected_count pod(s) are ready"
            return 0
        fi

        echo -n "."
        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo ""
    log_error "Timeout waiting for pods to be ready"
    kubectl get pods -n "$namespace" -l "$label"
    return 1
}

#######################################
# Installation Functions
#######################################

install_prerequisites() {
    log_info "Checking for required tools..."

    local missing_tools=()
    for tool in podman kubectl helm helmfile kind jq yq; do
        if ! check_command "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warn "Missing tools: ${missing_tools[*]}"
        log_info "Install with: brew install ${missing_tools[*]}"
        read -p "Would you like to install them now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            brew install "${missing_tools[@]}"
        else
            log_error "Cannot proceed without required tools"
            exit 1
        fi
    fi

    log_success "All required tools are installed"
}

setup_podman_machine() {
    log_info "Setting up podman machine..."

    # Check if machine exists (podman adds * to current machine, so we need to strip it)
    if podman machine list --format "{{.Name}}" 2>/dev/null | sed 's/\*$//' | grep -q "^${PODMAN_MACHINE_NAME}$"; then
        log_info "Podman machine already exists. Checking configuration..."

        # Get current machine configuration
        # Note: DiskSize is already in GB, Memory is in MB, CPUs is a number
        local current_memory=$(podman machine inspect "$PODMAN_MACHINE_NAME" 2>/dev/null | jq -r '.[0].Resources.Memory' || echo "0")
        local current_cpus=$(podman machine inspect "$PODMAN_MACHINE_NAME" 2>/dev/null | jq -r '.[0].Resources.CPUs' || echo "0")
        local current_disk=$(podman machine inspect "$PODMAN_MACHINE_NAME" 2>/dev/null | jq -r '.[0].Resources.DiskSize' || echo "0")
        
        # Handle null values
        if [ "$current_disk" = "null" ]; then
            current_disk="0"
        fi

        log_info "Current config: ${current_memory}MB RAM, ${current_cpus} CPUs, ${current_disk}GB disk"
        log_info "Desired config: ${PODMAN_MEMORY}MB RAM, ${PODMAN_CPUS} CPUs, ${PODMAN_DISK}GB disk"

        # Check if configuration matches
        local needs_update=false
        if [ "$current_memory" != "$PODMAN_MEMORY" ] || [ "$current_cpus" != "$PODMAN_CPUS" ]; then
            needs_update=true
        fi

        # Disk size can't be changed after creation, so check if we need to recreate
        local needs_recreate=false
        if [ "$current_disk" != "0" ] && [ "$current_disk" -lt "$PODMAN_DISK" ]; then
            log_warn "Current disk size (${current_disk}GB) is less than required (${PODMAN_DISK}GB)"
            needs_recreate=true
        fi

        if [ "$needs_recreate" = true ]; then
            log_warn "Machine needs to be recreated to change disk size"
            
            # Stop if running
            if podman machine list --format "{{.Name}} {{.Running}}" | sed 's/\*$//' | grep "^${PODMAN_MACHINE_NAME}" | grep -q "true"; then
                log_info "Stopping existing podman machine..."
                podman machine stop "$PODMAN_MACHINE_NAME" || true
            fi

            log_info "Removing existing machine..."
            podman machine rm -f "$PODMAN_MACHINE_NAME"
            # Wait a moment for cleanup
            sleep 2
            # Verify removal before recreating
            if podman machine list --format "{{.Name}}" 2>/dev/null | sed 's/\*$//' | grep -q "^${PODMAN_MACHINE_NAME}$"; then
                log_error "Failed to remove existing machine. Please run: podman machine rm -f $PODMAN_MACHINE_NAME"
                exit 1
            fi
            
            log_info "Creating new podman machine with correct configuration..."
            podman machine init --cpus "$PODMAN_CPUS" --memory "$PODMAN_MEMORY" --disk-size "$PODMAN_DISK" "$PODMAN_MACHINE_NAME"
        elif [ "$needs_update" = true ]; then
            # Stop if running
            if podman machine list --format "{{.Name}} {{.Running}}" | sed 's/\*$//' | grep "^${PODMAN_MACHINE_NAME}" | grep -q "true"; then
                log_info "Stopping existing podman machine..."
                podman machine stop "$PODMAN_MACHINE_NAME" || true
            fi

            # Update CPU and memory configuration
            log_info "Updating machine resources to ${PODMAN_MEMORY}MB RAM, ${PODMAN_CPUS} CPUs..."
            if ! podman machine set --memory "$PODMAN_MEMORY" --cpus "$PODMAN_CPUS" "$PODMAN_MACHINE_NAME"; then
                log_warn "Could not update existing machine. Recreating..."
                podman machine rm -f "$PODMAN_MACHINE_NAME"
                sleep 2
                if podman machine list --format "{{.Name}}" 2>/dev/null | sed 's/\*$//' | grep -q "^${PODMAN_MACHINE_NAME}$"; then
                    log_error "Failed to remove existing machine. Please run: podman machine rm -f $PODMAN_MACHINE_NAME"
                    exit 1
                fi
                podman machine init --cpus "$PODMAN_CPUS" --memory "$PODMAN_MEMORY" --disk-size "$PODMAN_DISK" "$PODMAN_MACHINE_NAME"
            fi
        else
            log_success "Machine configuration is correct"
        fi
    else
        log_info "Creating podman machine (${PODMAN_MEMORY}MB RAM, ${PODMAN_CPUS} CPUs, ${PODMAN_DISK}GB disk)..."
        podman machine init --cpus "$PODMAN_CPUS" --memory "$PODMAN_MEMORY" --disk-size "$PODMAN_DISK" "$PODMAN_MACHINE_NAME"
    fi

    log_info "Starting podman machine..."
    podman machine start "$PODMAN_MACHINE_NAME" || true

    # Verify
    log_info "Verifying podman machine..."
    podman info > /dev/null

    log_success "Podman machine is ready"
}

create_kind_cluster() {
    log_info "Creating kind cluster..."

    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        log_warn "Kind cluster '${KIND_CLUSTER_NAME}' already exists. Skipping creation."
        return 0
    fi

    kind create cluster --name "$KIND_CLUSTER_NAME"

    # Verify
    kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"

    log_success "Kind cluster created successfully"
}

install_gateway_api() {
    log_info "Installing Gateway API CRDs..."

    cd "${REPO_ROOT}/guides/prereq/gateway-provider"
    ./install-gateway-provider-dependencies.sh

    log_success "Gateway API CRDs installed"
}

install_istio() {
    log_info "Installing Istio..."

    cd "${REPO_ROOT}/guides/prereq/gateway-provider"
    helmfile sync -f istio.helmfile.yaml

    # Wait for Istio to be ready
    wait_for_pods "istio-system" "app=istiod" 1 300

    log_success "Istio installed successfully"
}

install_prometheus() {
    log_info "Installing Prometheus stack..."

    cd "$REPO_ROOT"
    if ! ./docs/monitoring/scripts/install-prometheus-grafana.sh; then
        log_error "Prometheus installation script failed"
        return 1
    fi

    # The install script already waits for pods to be ready
    # Just verify the namespace and basic resources exist
    if ! kubectl get namespace llm-d-monitoring &>/dev/null; then
        log_error "Monitoring namespace was not created"
        return 1
    fi

    # Give it a moment for resources to appear
    log_info "Verifying Prometheus stack resources..."
    sleep 5
    
    # Check if at least some pods exist (don't require them to be ready yet)
    if ! kubectl get pods -n llm-d-monitoring &>/dev/null; then
        log_warn "No pods found in monitoring namespace yet, but continuing..."
    fi

    log_success "Prometheus stack installed successfully"
}

build_arm64_images() {
    log_info "Building ARM64 images..."

    # Create build directory
    mkdir -p "$BUILD_DIR"

    # Build routing sidecar
    log_info "Building routing sidecar image..."
    if ! podman images | grep -q "llm-d-routing-sidecar.*v0.4.0-rc.1-arm64"; then
        cd "$BUILD_DIR"
        if [ ! -d "$ROUTING_SIDECAR_REPO" ]; then
            git clone https://github.com/llm-d/llm-d-routing-sidecar.git
        fi
        cd llm-d-routing-sidecar
        git checkout main
        podman build --platform=linux/arm64 -t "$ROUTING_SIDECAR_IMAGE" .
        log_success "Routing sidecar image built"
    else
        log_info "Routing sidecar image already exists"
    fi

    # Build EPP
    log_info "Building EPP image..."
    if ! podman images | grep -q "gateway-api-inference-extension-epp.*v1.2.0-rc.1-arm64"; then
        cd "$BUILD_DIR"
        if [ ! -d "$EPP_REPO" ]; then
            git clone https://github.com/kubernetes-sigs/gateway-api-inference-extension.git
        fi
        cd gateway-api-inference-extension
        git checkout v1.2.0-rc.1
        
        # Patch Dockerfile for ARM64 build - simple approach that works
        log_info "Patching Dockerfile for ARM64 build..."
        # Just change GOARCH from amd64 to arm64 - keep it simple!
        sed -i '' 's/ENV GOARCH=amd64/ENV GOARCH=arm64/' Dockerfile
        
        podman build --platform=linux/arm64 -t "$EPP_IMAGE" .
        log_success "EPP image built"
    else
        log_info "EPP image already exists"
    fi

    # Pull vLLM image
    log_info "Pulling vLLM macOS image..."
    if ! podman images | grep -q "vllm-service.*macos"; then
        podman pull "$VLLM_IMAGE"
        log_success "vLLM image pulled"
    else
        log_info "vLLM image already exists"
    fi
}

load_images_into_kind() {
    log_info "Loading images into kind cluster..."

    # Save images to tar files if they don't exist
    if [ ! -f "$ROUTING_SIDECAR_TAR" ]; then
        log_info "Saving routing sidecar image to tar..."
        podman save "$ROUTING_SIDECAR_IMAGE" -o "$ROUTING_SIDECAR_TAR"
    fi

    if [ ! -f "$EPP_TAR" ]; then
        log_info "Saving EPP image to tar..."
        podman save "$EPP_IMAGE" -o "$EPP_TAR"
    fi

    if [ ! -f "$VLLM_TAR" ]; then
        log_info "Saving vLLM image to tar..."
        podman save "$VLLM_IMAGE" -o "$VLLM_TAR"
    fi

    # Load into kind
    log_info "Loading images into kind cluster..."
    kind load image-archive "$ROUTING_SIDECAR_TAR" --name "$KIND_CLUSTER_NAME"
    kind load image-archive "$EPP_TAR" --name "$KIND_CLUSTER_NAME"
    kind load image-archive "$VLLM_TAR" --name "$KIND_CLUSTER_NAME"

    # Verify
    log_info "Verifying images in cluster..."
    podman exec "${KIND_CLUSTER_NAME}-control-plane" crictl images | grep -E "routing-sidecar|epp|vllm" || {
        log_error "Images not found in cluster"
        exit 1
    }

    log_success "Images loaded into kind cluster"
}

deploy_helm_charts() {
    log_info "Deploying Helm charts..."

    # Create namespace
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        kubectl create namespace "$NAMESPACE"
    fi

    cd "$GUIDE_DIR"

    # Deploy with helmfile
    export NAMESPACE
    helmfile sync -n "$NAMESPACE"

    log_success "Helm charts deployed"
}

install_httproute() {
    log_info "Installing HTTPRoute..."

    cd "$GUIDE_DIR"
    kubectl apply -f httproute.yaml -n "$NAMESPACE"

    log_success "HTTPRoute installed"
}

wait_for_deployment() {
    log_info "Waiting for deployment to be ready..."
    log_info "This may take 5-10 minutes as vLLM compiles the model on CPU..."

    # Wait for EPP
    wait_for_pods "$NAMESPACE" "inferencepool=gaie-cpu-inference-epp" 1 300

    # Wait for Gateway (using component label, not name)
    wait_for_pods "$NAMESPACE" "app.kubernetes.io/component=inference-gateway" 1 300

    # Wait for model service pod (1 replica, 2 containers)
    log_info "Waiting for model service pod (this is the slow part - model loading + compilation)..."
    wait_for_pods "$NAMESPACE" "llm-d.ai/inferenceServing=true" 1 600

    log_success "All pods are ready!"
}

setup_port_forward() {
    log_info "Setting up port forwarding..."

    # Kill any existing port-forward
    pkill -f "kubectl port-forward.*infra-cpu-inference-inference-gateway-istio" || true

    # Start port forward in background
    kubectl port-forward -n "$NAMESPACE" svc/infra-cpu-inference-inference-gateway-istio 8000:80 > /tmp/kubectl-port-forward.log 2>&1 &

    sleep 3

    log_success "Port forwarding started on http://localhost:8000"
}

test_deployment() {
    log_info "Testing deployment..."

    # Test /v1/models endpoint
    log_info "Testing /v1/models endpoint..."
    if curl -s http://localhost:8000/v1/models | jq -e '.data[0].id' > /dev/null; then
        log_success "Model endpoint is responding"
    else
        log_error "Model endpoint test failed"
        return 1
    fi

    # Test inference
    log_info "Testing inference endpoint..."
    local response=$(curl -s http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{
            "model": "Qwen/Qwen2-0.5B-Instruct",
            "messages": [{"role": "user", "content": "Say hello in one sentence."}],
            "max_tokens": 20,
            "temperature": 0.7
        }' | jq -r '.choices[0].message.content' 2>/dev/null)

    if [ -n "$response" ] && [ "$response" != "null" ]; then
        log_success "Inference test passed!"
        echo -e "${GREEN}Response: $response${NC}"
    else
        log_error "Inference test failed"
        return 1
    fi

    log_success "All tests passed!"
}

#######################################
# Teardown Functions
#######################################

teardown_all() {
    local non_interactive=${1:-false}
    
    log_info "Starting teardown..."

    # Remove Helm deployments
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_info "Removing Helm deployments..."
        cd "$GUIDE_DIR"
        helmfile destroy -n "$NAMESPACE" 2>/dev/null || true

        # Remove HTTPRoute
        kubectl delete -f httproute.yaml -n "$NAMESPACE" 2>/dev/null || true

        # Delete namespace
        kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
    fi

    # Delete kind cluster
    if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        log_info "Deleting kind cluster..."
        kind delete cluster --name "$KIND_CLUSTER_NAME"
    fi

    # Stop podman machine
    if podman machine list --format "{{.Name}}" 2>/dev/null | sed 's/\*$//' | grep -q "^${PODMAN_MACHINE_NAME}$"; then
        log_info "Stopping podman machine..."
        podman machine stop "$PODMAN_MACHINE_NAME" 2>/dev/null || true

        if [ "$non_interactive" = true ]; then
            log_info "Non-interactive mode: keeping podman machine"
        else
            read -p "Remove podman machine and reclaim 100GB disk space? [y/N] " -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Removing podman machine..."
                podman machine rm -f "$PODMAN_MACHINE_NAME"
                log_success "Podman machine removed"
            else
                log_info "Keeping podman machine"
            fi
        fi
    fi

    # Clean up images
    if [ "$non_interactive" = true ]; then
        log_info "Non-interactive mode: keeping container images"
    else
        read -p "Remove local container images? [y/N] " -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Removing container images..."
            podman rmi "$ROUTING_SIDECAR_IMAGE" 2>/dev/null || true
            podman rmi "$EPP_IMAGE" 2>/dev/null || true
            podman rmi "$VLLM_IMAGE" 2>/dev/null || true
            log_success "Images removed"
        else
            log_info "Keeping container images"
        fi
    fi

    # Clean up tar files
    log_info "Removing tar files..."
    rm -f "$ROUTING_SIDECAR_TAR" "$EPP_TAR" "$VLLM_TAR"

    # Clean up build directory
    log_info "Removing build directory..."
    rm -rf "$BUILD_DIR"

    # Kill port forwards
    pkill -f "kubectl port-forward.*infra-cpu-inference" || true

    log_success "Teardown complete!"
}

#######################################
# Main Deployment Flow
#######################################

deploy_all() {
    log_info "Starting llm-d CPU inference scheduling deployment..."
    echo ""

    # Step 1: Install prerequisites
    install_prerequisites
    echo ""

    # Step 2: Setup podman machine
    setup_podman_machine
    echo ""

    # Step 3: Create kind cluster
    create_kind_cluster
    echo ""

    # Step 4: Install Gateway API
    install_gateway_api
    echo ""

    # Step 5: Install Istio
    install_istio
    echo ""

    # Step 6: Install Prometheus
    install_prometheus
    echo ""

    # Step 7: Build ARM64 images
    build_arm64_images
    echo ""

    # Step 8: Load images into kind
    load_images_into_kind
    echo ""

    # Step 9: Deploy Helm charts
    deploy_helm_charts
    echo ""

    # Step 10: Install HTTPRoute
    install_httproute
    echo ""

    # Step 11: Wait for deployment
    wait_for_deployment
    echo ""

    # Step 12: Setup port forwarding
    setup_port_forward
    echo ""

    # Step 13: Test deployment
    test_deployment
    echo ""

    log_success "🎉 Deployment complete!"
    echo ""
    echo -e "${GREEN}Next steps:${NC}"
    echo -e "  - Test inference: curl -s http://localhost:8000/v1/models | jq"
    echo -e "  - View logs: kubectl logs -n $NAMESPACE -l llm-d.ai/inferenceServing=true -c vllm -f"
    echo -e "  - Port forward Prometheus: kubectl port-forward -n llm-d-monitoring svc/llmd-kube-prometheus-stack-prometheus 9090:9090"
    echo -e "  - Port forward Grafana: kubectl port-forward -n llm-d-monitoring svc/llmd-grafana 3000:80"
    echo ""
    echo -e "${YELLOW}To teardown:${NC} $0 --teardown"
}

#######################################
# Main
#######################################

main() {
    local non_interactive=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --teardown)
                shift
                teardown_all "$non_interactive"
                return
                ;;
            --non-interactive)
                non_interactive=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Usage: $0 [--teardown] [--non-interactive]"
                exit 1
                ;;
        esac
    done
    
    # If no teardown flag, deploy
    deploy_all
}

# Run main
main "$@"

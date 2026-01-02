#!/usr/bin/env bash

#######################################
# llm-d CPU Inference Scheduling Deployment Script
#
# This script automates the complete deployment of llm-d intelligent
# inference scheduling using Minikube with support for CPU, GPU, and Mac Metal.
#
# Usage:
#   ./deploy.sh                    # Deploy everything (auto-detect backend)
#   ./deploy.sh --driver docker    # Use Docker driver
#   ./deploy.sh --driver podman    # Use Podman driver
#   ./deploy.sh --gpu              # Enable GPU support (requires nvidia-docker)
#   ./deploy.sh --teardown         # Remove everything
#
# Requirements:
#   - Mac (Apple Silicon or Intel) or Linux
#   - 24GB+ RAM (for Minikube VM)
#   - 100GB+ free disk space
#   - Homebrew installed (Mac) or package manager (Linux)
#######################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MINIKUBE_PROFILE="llm-d-cpu"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-auto}"  # auto, docker, podman
MINIKUBE_MEMORY="24576"  # 24GB
MINIKUBE_CPUS="8"
MINIKUBE_DISK="100g"
ENABLE_GPU="${ENABLE_GPU:-false}"
NAMESPACE="llm-d-cpu-inference"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUIDE_DIR="${REPO_ROOT}/guides/cpu-inference-scheduling"

# Temporary build directories
BUILD_DIR="/tmp/llm-d-build-$$"
ROUTING_SIDECAR_REPO="${BUILD_DIR}/llm-d-routing-sidecar"
EPP_REPO="${BUILD_DIR}/gateway-api-inference-extension"

# Quay.io image names
QUAY_USERNAME="${QUAY_USERNAME:-petecheslock}"
ROUTING_SIDECAR_IMAGE="quay.io/${QUAY_USERNAME}/llm-d-routing-sidecar:v0.4.0-rc.1-arm64"
EPP_IMAGE="quay.io/${QUAY_USERNAME}/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64"
VLLM_IMAGE="quay.io/${QUAY_USERNAME}/llm-d-cpu:v0.4.0-arm64"

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
    local required_tools="kubectl helm helmfile minikube jq yq"

    # Add driver-specific tools
    if [ "$MINIKUBE_DRIVER" = "podman" ]; then
        required_tools="$required_tools podman"
    elif [ "$MINIKUBE_DRIVER" = "docker" ]; then
        required_tools="$required_tools docker"
    fi

    for tool in $required_tools; do
        if ! check_command "$tool"; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warn "Missing tools: ${missing_tools[*]}"

        # Detect OS and provide appropriate install command
        if [[ "$OSTYPE" == "darwin"* ]]; then
            log_info "Install with: brew install ${missing_tools[*]}"
            read -p "Would you like to install them now? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                brew install "${missing_tools[@]}"
            else
                log_error "Cannot proceed without required tools"
                exit 1
            fi
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            log_info "Install minikube: https://minikube.sigs.k8s.io/docs/start/"
            log_info "Install other tools with your package manager"
            exit 1
        fi
    fi

    log_success "All required tools are installed"
}

setup_podman_machine() {
    # Only needed on macOS
    if [[ "$OSTYPE" != "darwin"* ]]; then
        return 0
    fi

    log_info "Checking Podman machine status..."

    # Podman machine needs to be larger than Minikube's requirements
    # Minikube needs: 8 CPUs, 24GB RAM
    # Podman machine should have: 10 CPUs, 28GB RAM (with overhead)
    local required_cpus=10
    local required_memory=28672  # 28GB in MB

    # Check if any Podman machine exists
    local machine_count=$(podman machine list --format json 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")

    if [ "$machine_count" = "0" ]; then
        log_info "No Podman machine found, creating one..."
        log_info "This will download the Podman machine image (~1GB) and allocate ${required_cpus} CPUs, ${required_memory}MB RAM..."
        log_warn "Note: This requires sufficient host resources. Adjust MINIKUBE_* variables if needed."
        
        # Create with rootful mode for Kubernetes compatibility
        if ! podman machine init --cpus "$required_cpus" --memory "$required_memory" --disk-size 120 --rootful; then
            log_error "Failed to initialize Podman machine"
            log_warn "Try with fewer resources: podman machine init --cpus 8 --memory 26624 --rootful"
            return 1
        fi
        
        log_success "Podman machine initialized (rootful mode for Kubernetes)"
    else
        # Check if existing machine has enough resources
        local existing_cpus=$(podman machine list --format json 2>/dev/null | jq '.[0].CPUs' 2>/dev/null || echo "0")
        local existing_memory_gb=$(podman machine list --format json 2>/dev/null | jq '.[0].Memory' 2>/dev/null | sed 's/GiB//' || echo "0")
        
        if [ "$existing_cpus" -lt 8 ]; then
            log_warn "Existing Podman machine has only ${existing_cpus} CPUs (need 8+)"
            log_warn "Consider removing and recreating: podman machine rm -f && podman machine init --cpus $required_cpus --memory $required_memory"
            log_info "Continuing anyway - Minikube may fail to start..."
        fi
    fi

    # Check if machine is running
    local running_count=$(podman machine list --format json 2>/dev/null | jq '[.[] | select(.Running==true)] | length' 2>/dev/null || echo "0")

    if [ "$running_count" = "0" ]; then
        log_info "Starting Podman machine..."
        if ! podman machine start; then
            log_error "Failed to start Podman machine"
            return 1
        fi
        log_success "Podman machine started"
        
        # Give it a moment to be fully ready
        sleep 5
    else
        log_success "Podman machine is already running"
    fi

    # Verify cgroup v2 with cpuset is available
    log_info "Verifying cgroup v2 controllers..."
    if podman machine ssh -- "cat /sys/fs/cgroup/cgroup.controllers" 2>/dev/null | grep -q cpuset; then
        log_success "cgroup v2 with cpuset controller confirmed"
    else
        log_warn "cpuset controller not found in cgroup v2"
        log_warn "Kubernetes may have issues - consider using Docker Desktop"
    fi

    return 0
}

detect_platform() {
    log_info "Detecting platform and available drivers..."

    local detected_driver=""
    local platform_info=""

    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Mac - check for Apple Silicon vs Intel
        local arch=$(uname -m)
        if [ "$arch" = "arm64" ]; then
            platform_info="Apple Silicon Mac detected"
        else
            platform_info="Intel Mac detected"
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux - check for GPU
        if command -v nvidia-smi &> /dev/null; then
            platform_info="Linux with NVIDIA GPU detected"
        else
            platform_info="Linux detected"
        fi
    fi

    log_info "$platform_info"

    # Use auto-detected driver if not explicitly set
    if [ "$MINIKUBE_DRIVER" = "auto" ]; then
        # Check which drivers are available
        if command -v podman &> /dev/null; then
            detected_driver="podman"
            log_info "Podman detected, using podman driver"
        elif command -v docker &> /dev/null; then
            detected_driver="docker"
            log_info "Docker detected, using docker driver"
        else
            log_error "No container runtime found. Please install Docker or Podman."
            exit 1
        fi
        MINIKUBE_DRIVER="$detected_driver"
    else
        log_info "Using driver: $MINIKUBE_DRIVER"
    fi

    # Setup Podman machine if using Podman on macOS
    if [ "$MINIKUBE_DRIVER" = "podman" ] && [[ "$OSTYPE" == "darwin"* ]]; then
        setup_podman_machine
    fi
}

start_minikube() {
    log_info "Starting Minikube cluster..."

    # Check if profile already exists
    if minikube profile list -o json 2>/dev/null | jq -e ".valid[] | select(.Name == \"$MINIKUBE_PROFILE\")" > /dev/null 2>&1; then
        log_info "Minikube profile '$MINIKUBE_PROFILE' already exists"

        # Check if the actual Podman container exists (if using Podman)
        if [ "$MINIKUBE_DRIVER" = "podman" ]; then
            if ! podman container exists "$MINIKUBE_PROFILE" 2>/dev/null; then
                log_warn "Minikube profile exists but Podman container is missing"
                log_info "Cleaning up orphaned profile and volumes..."
                
                # Remove orphaned volumes
                podman volume ls -q --filter label=name.minikube.sigs.k8s.io="$MINIKUBE_PROFILE" 2>/dev/null | while read vol; do
                    if [ -n "$vol" ]; then
                        log_info "Removing orphaned volume: $vol"
                        podman volume rm -f "$vol" 2>/dev/null || true
                    fi
                done
                
                # Delete the orphaned profile
                minikube delete -p "$MINIKUBE_PROFILE" 2>/dev/null || true
                
                log_info "Will create fresh Minikube cluster..."
                # Fall through to create new cluster below
            else
                # Container exists, try to start it
                local status=$(minikube status -p "$MINIKUBE_PROFILE" -o json 2>/dev/null | jq -r '.Host' || echo "Stopped")

                if [ "$status" != "Running" ]; then
                    log_info "Starting existing Minikube cluster..."
                    minikube start -p "$MINIKUBE_PROFILE"
                else
                    log_success "Minikube cluster is already running"
                fi
                
                # Set kubectl context and verify
                kubectl config use-context "$MINIKUBE_PROFILE"
                kubectl cluster-info
                log_success "Minikube cluster is ready"
                return 0
            fi
        else
            # Not using Podman driver, standard check
            local status=$(minikube status -p "$MINIKUBE_PROFILE" -o json 2>/dev/null | jq -r '.Host' || echo "Stopped")

            if [ "$status" != "Running" ]; then
                log_info "Starting existing Minikube cluster..."
                minikube start -p "$MINIKUBE_PROFILE"
            else
                log_success "Minikube cluster is already running"
            fi
            
            # Set kubectl context and verify
            kubectl config use-context "$MINIKUBE_PROFILE"
            kubectl cluster-info
            log_success "Minikube cluster is ready"
            return 0
        fi
    fi
    
    # Create new cluster (no profile exists or we cleaned up orphaned state)
    log_info "Creating new Minikube cluster (${MINIKUBE_MEMORY}MB RAM, ${MINIKUBE_CPUS} CPUs, ${MINIKUBE_DISK} disk)..."

    local start_args=(
        -p "$MINIKUBE_PROFILE"
        --driver="$MINIKUBE_DRIVER"
        --memory="$MINIKUBE_MEMORY"
        --cpus="$MINIKUBE_CPUS"
        --disk-size="$MINIKUBE_DISK"
    )

    # Configure for cgroup v2 with Podman libkrun
    if [ "$MINIKUBE_DRIVER" = "podman" ] && [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "Configuring Minikube for cgroup v2 (Podman libkrun)..."
        # Podman libkrun uses cgroup v2 unified hierarchy
        start_args+=(
            --extra-config=kubelet.cgroup-driver=systemd
            --extra-config=kubeadm.ignore-preflight-errors=SystemVerification
        )
    fi

    # Add GPU support if enabled
    if [ "$ENABLE_GPU" = "true" ]; then
        log_info "Enabling GPU support..."
        start_args+=(--gpus all)
    fi

    # Mac Metal acceleration (Apple Silicon + Docker Desktop only)
    if [[ "$OSTYPE" == "darwin"* ]] && [ "$(uname -m)" = "arm64" ] && [ "$MINIKUBE_DRIVER" = "docker" ]; then
        log_info "Mac Metal acceleration available (automatic with Docker Desktop)"
    fi

    minikube start "${start_args[@]}"

    # Set kubectl context
    kubectl config use-context "$MINIKUBE_PROFILE"

    # Verify
    kubectl cluster-info

    log_success "Minikube cluster is ready"
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

verify_quay_images() {
    log_info "Verifying Quay images are accessible..."
    log_info "Using Quay username: $QUAY_USERNAME"

    local images=(
        "$ROUTING_SIDECAR_IMAGE"
        "$EPP_IMAGE"
        "$VLLM_IMAGE"
    )

    local pull_cmd="docker"
    if [ "$MINIKUBE_DRIVER" = "podman" ]; then
        pull_cmd="podman"
    fi

    # Check if we can access the images (pull metadata)
    for img in "${images[@]}"; do
        log_info "Verifying $img..."
        if ! $pull_cmd manifest inspect "$img" > /dev/null 2>&1; then
            log_warn "Cannot access $img"
            log_warn ""
            log_warn "This could mean:"
            log_warn "  1. Images haven't been pushed to Quay yet"
            log_warn "  2. Images are private and you need to login: $pull_cmd login quay.io"
            log_warn "  3. Images need to be made public in Quay.io settings"
            log_warn ""
            log_warn "To build and push images, run:"
            log_warn "  ./build-and-push-to-quay.sh"
            log_warn ""
            log_info "Continuing anyway - Minikube will attempt to pull during deployment..."
        else
            log_success "Verified: $img"
        fi
    done

    log_info "Note: Minikube will pull images from Quay.io during deployment"
    log_info "If images are private, you may need to configure imagePullSecrets"
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

    # Wait for model service pods (2 replicas, 2 containers each)
    log_info "Waiting for model service pods (this is the slow part - model loading + compilation)..."
    wait_for_pods "$NAMESPACE" "llm-d.ai/inferenceServing=true" 2 900

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
            "model": "HuggingFaceTB/SmolLM2-360M-Instruct",
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

    # Delete Minikube cluster
    if minikube profile list -o json 2>/dev/null | jq -e ".valid[] | select(.Name == \"$MINIKUBE_PROFILE\")" > /dev/null 2>&1; then
        if [ "$non_interactive" = true ]; then
            log_info "Deleting Minikube cluster..."
            minikube delete -p "$MINIKUBE_PROFILE"
        else
            read -p "Delete Minikube cluster and reclaim disk space? [y/N] " -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Deleting Minikube cluster..."
                minikube delete -p "$MINIKUBE_PROFILE"
                log_success "Minikube cluster deleted"
            else
                log_info "Stopping Minikube cluster..."
                minikube stop -p "$MINIKUBE_PROFILE" 2>/dev/null || true
                log_info "Minikube cluster stopped (use 'minikube start -p $MINIKUBE_PROFILE' to restart)"
            fi
        fi
    fi

    # Clean up leftover Podman volumes (if using Podman driver)
    if [ "$MINIKUBE_DRIVER" = "podman" ] && command -v podman &> /dev/null; then
        log_info "Cleaning up Podman volumes..."
        podman volume ls -q --filter label=name.minikube.sigs.k8s.io="$MINIKUBE_PROFILE" 2>/dev/null | while read vol; do
            if [ -n "$vol" ]; then
                log_info "Removing Podman volume: $vol"
                podman volume rm -f "$vol" 2>/dev/null || true
            fi
        done
    fi

    # Kill port forwards
    pkill -f "kubectl port-forward.*infra-cpu-inference" || true

    log_success "Teardown complete!"
}

#######################################
# Main Deployment Flow
#######################################

deploy_all() {
    log_info "Starting llm-d CPU inference scheduling deployment with Minikube..."
    echo ""

    # Step 1: Install prerequisites
    install_prerequisites
    echo ""

    # Step 2: Detect platform and set driver
    detect_platform
    echo ""

    # Step 3: Start Minikube cluster
    start_minikube
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

    # Step 7: Verify Quay images are accessible
    verify_quay_images
    echo ""

    # Step 8: Deploy Helm charts (Minikube will pull images from Quay)
    deploy_helm_charts
    echo ""

    # Step 9: Install HTTPRoute
    install_httproute
    echo ""

    # Step 10: Wait for deployment
    wait_for_deployment
    echo ""

    # Step 11: Setup port forwarding
    setup_port_forward
    echo ""

    # Step 12: Test deployment
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
    echo -e "${YELLOW}Minikube info:${NC}"
    echo -e "  - Profile: $MINIKUBE_PROFILE"
    echo -e "  - Driver: $MINIKUBE_DRIVER"
    echo -e "  - Dashboard: minikube dashboard -p $MINIKUBE_PROFILE"
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
            --driver)
                MINIKUBE_DRIVER="$2"
                shift 2
                ;;
            --gpu)
                ENABLE_GPU=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --driver <docker|podman>  Specify Minikube driver (default: auto-detect)"
                echo "  --gpu                     Enable GPU support (Linux only)"
                echo "  --teardown                Remove deployment and cluster"
                echo "  --non-interactive         Non-interactive teardown (keeps cluster stopped)"
                echo "  --help, -h                Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0                        # Auto-detect and deploy"
                echo "  $0 --driver docker        # Use Docker driver"
                echo "  $0 --driver podman        # Use Podman driver"
                echo "  $0 --gpu                  # Enable GPU support"
                echo "  $0 --teardown             # Interactive teardown"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # If no teardown flag, deploy
    deploy_all
}

# Run main
main "$@"

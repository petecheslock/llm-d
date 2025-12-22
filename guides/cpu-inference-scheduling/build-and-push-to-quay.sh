#!/usr/bin/env bash

#######################################
# Build and Push llm-d v0.4.0 Containers to Quay.io
#
# This script builds the three required containers for llm-d CPU inference
# scheduling and pushes them to your Quay.io account.
#
# Usage:
#   ./build-and-push-to-quay.sh
#
# Requirements:
#   - Logged into Quay.io: podman login quay.io
#   - Podman machine running
#   - llm-d repository at v0.4.0 or compatible
#######################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
QUAY_USERNAME="${QUAY_USERNAME:-petecheslock}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="/tmp/llm-d-quay-build-$$"

# Image names - local tags
ROUTING_SIDECAR_LOCAL="localhost/llm-d-routing-sidecar:v0.4.0-rc.1-arm64"
EPP_LOCAL="localhost/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64"
VLLM_LOCAL="localhost/llm-d-cpu:v0.4.0-arm64"

# Image names - Quay tags
ROUTING_SIDECAR_QUAY="quay.io/${QUAY_USERNAME}/llm-d-routing-sidecar:v0.4.0-rc.1-arm64"
EPP_QUAY="quay.io/${QUAY_USERNAME}/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64"
VLLM_QUAY="quay.io/${QUAY_USERNAME}/llm-d-cpu:v0.4.0-arm64"

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

check_quay_login() {
    log_info "Checking Quay.io login..."
    if ! podman login quay.io --get-login &>/dev/null; then
        log_error "Not logged into Quay.io"
        echo "Please run: podman login quay.io"
        exit 1
    fi
    local username=$(podman login quay.io --get-login)
    log_success "Logged into Quay.io as: $username"
    
    if [ "$username" != "$QUAY_USERNAME" ]; then
        log_warn "Logged in as '$username' but QUAY_USERNAME is set to '$QUAY_USERNAME'"
        read -p "Continue with username '$username'? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        QUAY_USERNAME="$username"
        # Update Quay image names
        ROUTING_SIDECAR_QUAY="quay.io/${QUAY_USERNAME}/llm-d-routing-sidecar:v0.4.0-rc.1-arm64"
        EPP_QUAY="quay.io/${QUAY_USERNAME}/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64"
        VLLM_QUAY="quay.io/${QUAY_USERNAME}/llm-d-cpu:v0.4.0-arm64"
    fi
}

build_routing_sidecar() {
    log_info "Building routing sidecar..."
    
    if podman images | grep -q "llm-d-routing-sidecar.*v0.4.0-rc.1-arm64"; then
        log_info "Routing sidecar image already exists locally, skipping build"
        return 0
    fi
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    if [ ! -d "llm-d-routing-sidecar" ]; then
        git clone https://github.com/llm-d/llm-d-routing-sidecar.git
    fi
    
    cd llm-d-routing-sidecar
    git checkout main
    
    podman build --platform=linux/arm64 -t "$ROUTING_SIDECAR_LOCAL" .
    log_success "Routing sidecar built"
}

build_epp() {
    log_info "Building EPP (Gateway API Inference Extension)..."
    
    if podman images | grep -q "gateway-api-inference-extension-epp.*v1.2.0-rc.1-arm64"; then
        log_info "EPP image already exists locally, skipping build"
        return 0
    fi
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    if [ ! -d "gateway-api-inference-extension" ]; then
        git clone https://github.com/kubernetes-sigs/gateway-api-inference-extension.git
    fi
    
    cd gateway-api-inference-extension
    git checkout v1.2.0-rc.1
    
    # Patch Dockerfile for ARM64
    log_info "Patching Dockerfile for ARM64..."
    sed -i '' 's/ENV GOARCH=amd64/ENV GOARCH=arm64/' Dockerfile
    
    podman build --platform=linux/arm64 -t "$EPP_LOCAL" .
    log_success "EPP built"
}

build_vllm() {
    log_info "Building llm-d-cpu (vLLM)..."
    log_warn "This takes 15-30 minutes - building vLLM from source"
    
    if podman images | grep -q "llm-d-cpu.*v0.4.0-arm64"; then
        log_info "llm-d-cpu image already exists locally, skipping build"
        return 0
    fi
    
    cd "$REPO_ROOT"
    
    podman build \
        --platform=linux/arm64 \
        --build-arg TARGETARCH=arm64 \
        --build-arg PYTHON_VERSION=3.12 \
        --build-arg max_jobs=4 \
        -t "$VLLM_LOCAL" \
        -f docker/Dockerfile.cpu \
        .
    
    log_success "llm-d-cpu built"
}

tag_and_push() {
    local local_image=$1
    local quay_image=$2
    local name=$3
    
    log_info "Tagging and pushing $name to Quay.io..."
    
    # Tag for Quay
    podman tag "$local_image" "$quay_image"
    
    # Push to Quay
    podman push "$quay_image"
    
    log_success "$name pushed to $quay_image"
}

print_summary() {
    echo ""
    echo "=========================================="
    log_success "All images built and pushed to Quay.io!"
    echo "=========================================="
    echo ""
    echo "Images available at:"
    echo "  1. $ROUTING_SIDECAR_QUAY"
    echo "  2. $EPP_QUAY"
    echo "  3. $VLLM_QUAY"
    echo ""
    echo "To make these images public (optional):"
    echo "  1. Visit https://quay.io/repository/$QUAY_USERNAME/llm-d-routing-sidecar?tab=settings"
    echo "  2. Visit https://quay.io/repository/$QUAY_USERNAME/gateway-api-inference-extension-epp?tab=settings"
    echo "  3. Visit https://quay.io/repository/$QUAY_USERNAME/llm-d-cpu?tab=settings"
    echo "  4. Change visibility to 'Public'"
    echo ""
    echo "Next steps:"
    echo "  - Update deploy.sh to use these Quay images"
    echo "  - Update values.yaml files with the new image references"
    echo ""
}

#######################################
# Main Flow
#######################################

main() {
    log_info "Starting build and push to Quay.io..."
    echo ""
    
    # Check prerequisites
    check_quay_login
    echo ""
    
    # Build images
    log_info "Step 1/6: Building routing sidecar"
    build_routing_sidecar
    echo ""
    
    log_info "Step 2/6: Building EPP"
    build_epp
    echo ""
    
    log_info "Step 3/6: Building llm-d-cpu (this is the slow one)"
    build_vllm
    echo ""
    
    # Tag and push
    log_info "Step 4/6: Pushing routing sidecar"
    tag_and_push "$ROUTING_SIDECAR_LOCAL" "$ROUTING_SIDECAR_QUAY" "routing sidecar"
    echo ""
    
    log_info "Step 5/6: Pushing EPP"
    tag_and_push "$EPP_LOCAL" "$EPP_QUAY" "EPP"
    echo ""
    
    log_info "Step 6/6: Pushing llm-d-cpu"
    tag_and_push "$VLLM_LOCAL" "$VLLM_QUAY" "llm-d-cpu"
    echo ""
    
    # Cleanup
    log_info "Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
    
    print_summary
}

main "$@"


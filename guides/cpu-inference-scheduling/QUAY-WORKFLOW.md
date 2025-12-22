# Using Quay.io for llm-d v0.4.0 Container Images

This guide explains how to build llm-d v0.4.0 containers locally and push them to your Quay.io account instead of loading them into KIND directly.

## Why Use Quay.io?

**Benefits:**
- ✅ Build once, deploy many times (no need to rebuild for each cluster)
- ✅ Share images across different machines/environments
- ✅ Faster deployment (pull from registry vs rebuild + load)
- ✅ Version control and image history via Quay UI
- ✅ Can make images public for others to use

**Current Approach (Local + KIND):**
- Build images locally with podman
- Save to tar files
- Load tar files into KIND cluster
- Images only available in that specific KIND cluster

**Quay Approach:**
- Build images locally with podman
- Push to Quay.io registry
- KIND pulls images from Quay (like any other registry)
- Images available to any cluster with registry access

## Prerequisites

1. **Quay.io Account**: Create free account at https://quay.io
2. **Podman Login**: Authenticate to Quay.io
3. **Podman Machine Running**: `podman machine start`

## Quick Start

### Step 1: Login to Quay.io

```bash
# Login to Quay.io (one-time setup)
podman login quay.io

# Verify you're logged in
podman login quay.io --get-login
# Should output your username (e.g., petecheslock)
```

### Step 2: Build and Push Images

```bash
cd /Users/pchesloc/repos/llm-d/guides/cpu-inference-scheduling

# Run the build and push script
./build-and-push-to-quay.sh
```

**This script will:**
1. ✅ Check you're logged into Quay.io
2. ✅ Build routing-sidecar (if not already built)
3. ✅ Build EPP (if not already built)
4. ✅ Build llm-d-cpu from source (~15-30 min)
5. ✅ Tag all images for your Quay account
6. ✅ Push all images to Quay.io

**Output images:**
- `quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64`
- `quay.io/petecheslock/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64`
- `quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64`

### Step 3: Make Images Public (Optional but Recommended)

By default, Quay creates **private** repositories. To allow your KIND cluster to pull without authentication:

1. Visit your Quay repositories:
   - https://quay.io/repository/petecheslock/llm-d-routing-sidecar?tab=settings
   - https://quay.io/repository/petecheslock/gateway-api-inference-extension-epp?tab=settings
   - https://quay.io/repository/petecheslock/llm-d-cpu?tab=settings

2. For each repository:
   - Click the **Settings** tab
   - Find "Repository Visibility"
   - Change from "Private" to **"Public"**
   - Click "Save"

**Note:** If you keep images private, you'll need to configure imagePullSecrets in Kubernetes.

### Step 4: Update Deployment Configuration

Update the values.yaml files to reference your Quay images:

**Edit `ms-inference-scheduling/values.yaml`:**

```yaml
decode:
  containers:
  - name: "vllm"
    image: quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64
    imagePullPolicy: IfNotPresent
```

**Edit `gaie-inference-scheduling/values.yaml`:**

```yaml
image:
  repository: quay.io/petecheslock/gateway-api-inference-extension-epp
  tag: v1.2.0-rc.1-arm64
  pullPolicy: IfNotPresent
```

**Edit `infra-inference-scheduling/values.yaml`** (if needed - check file exists):

```yaml
routing:
  proxy:
    image: quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64
    imagePullPolicy: IfNotPresent
```

**Or update in `ms-inference-scheduling/values.yaml`:**

```yaml
routing:
  proxy:
    image: quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64
    imagePullPolicy: IfNotPresent
```

### Step 5: Update deploy.sh (Optional)

Modify `deploy.sh` to use Quay images instead of building locally. Replace the `build_arm64_images()` and `load_images_into_kind()` functions with:

```bash
verify_quay_images() {
    log_info "Verifying Quay images are available..."
    
    local images=(
        "quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64"
        "quay.io/petecheslock/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64"
        "quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64"
    )
    
    for img in "${images[@]}"; do
        if ! podman pull "$img" --quiet; then
            log_error "Failed to pull $img from Quay"
            log_error "Make sure you've run: ./build-and-push-to-quay.sh"
            log_error "And made the images public in Quay.io settings"
            exit 1
        fi
        log_success "Verified: $img"
    done
}
```

Then in the `deploy_all()` function, replace steps 7-8 with:

```bash
# Step 7: Verify Quay images
verify_quay_images
echo ""
# (Remove step 8 - no longer need to load into kind)
```

KIND will now pull images directly from Quay.io when deploying.

### Step 6: Deploy

```bash
# Deploy with Quay images
./deploy.sh
```

KIND will automatically pull the images from Quay.io during deployment.

## Workflow Summary

```
┌──────────────────────────────────────────────────────────┐
│  Developer Machine                                        │
│  ┌────────────────────────────────────────────────────┐  │
│  │ 1. Build images locally with podman                │  │
│  │    ./build-and-push-to-quay.sh                     │  │
│  └────────────┬───────────────────────────────────────┘  │
│               │                                           │
│               │ podman push                               │
│               ▼                                           │
└───────────────┼───────────────────────────────────────────┘
                │
        ┌───────▼────────┐
        │   Quay.io      │
        │   Registry     │
        │                │
        │ - routing-     │
        │   sidecar      │
        │ - epp          │
        │ - llm-d-cpu    │
        └───────┬────────┘
                │
                │ podman pull (via KIND)
                │
┌───────────────▼───────────────────────────────────────────┐
│  KIND Cluster                                             │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Pulls images from Quay.io during deployment     │    │
│  │  - No local tar files needed                     │    │
│  │  - No image loading step needed                  │    │
│  └──────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────┘
```

## Troubleshooting

### "manifest unknown" error when pulling

**Problem:** KIND can't pull from Quay.io

**Solutions:**
1. Verify images exist in Quay.io web UI
2. Make sure repositories are set to **Public**
3. Check image tags match exactly (including `-arm64` suffix)

### "unauthorized" error when pulling

**Problem:** Images are private

**Solutions:**
1. Make repositories public (recommended for testing)
2. Or create imagePullSecret in Kubernetes:

```bash
# Create secret
kubectl create secret docker-registry quay-secret \
  --docker-server=quay.io \
  --docker-username=petecheslock \
  --docker-password=<your-token> \
  -n llm-d-cpu-inference

# Reference in values.yaml
imagePullSecrets:
  - name: quay-secret
```

### Build script fails with "not logged in"

**Problem:** Not authenticated to Quay.io

**Solution:**
```bash
podman login quay.io
# Enter username and password/token
```

### Want to rebuild a specific image

**Problem:** Need to rebuild just one image

**Solution:**
```bash
# Delete local image first
podman rmi localhost/llm-d-cpu:v0.4.0-arm64

# Re-run script (will only rebuild missing images)
./build-and-push-to-quay.sh
```

## Alternative: Using Docker Hub or Other Registries

The same approach works with other registries:

**Docker Hub:**
```bash
# Login
podman login docker.io

# Update script to use docker.io/username/...
# Or set environment variable
QUAY_USERNAME=petecheslock REGISTRY=docker.io ./build-and-push-to-quay.sh
```

**GitHub Container Registry:**
```bash
# Login
podman login ghcr.io

# Update script to use ghcr.io/username/...
```

## Cleanup

```bash
# Remove local images (optional - keeps them in Quay)
podman rmi quay.io/petecheslock/llm-d-routing-sidecar:v0.4.0-rc.1-arm64
podman rmi quay.io/petecheslock/gateway-api-inference-extension-epp:v1.2.0-rc.1-arm64
podman rmi quay.io/petecheslock/llm-d-cpu:v0.4.0-arm64

# Images remain in Quay.io and can be re-pulled anytime
```

## Next Steps

Once images are in Quay.io:
1. Update all values.yaml files with Quay image references
2. Run `./deploy.sh` - KIND will pull from Quay automatically
3. Share the Quay image URLs with others who want to use llm-d v0.4.0 on ARM64


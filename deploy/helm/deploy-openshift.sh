#!/bin/bash
# AIRA OpenShift Deployment Script
#
# Deploys the NVIDIA RAG Blueprint (prerequisite) and AIRA Blueprint
# on OpenShift with all required adaptations.
#
# Usage:
#   NGC_API_KEY=nvapi-... NVIDIA_API_KEY=nvapi-... AIRA_NAMESPACE=aira bash deploy/helm/deploy-openshift.sh
#   NGC_API_KEY=nvapi-... NVIDIA_API_KEY=nvapi-... AIRA_NAMESPACE=aira GPU_TOLERATION_KEYS=g6-gpu,p4-gpu,nvidia.com/gpu bash deploy/helm/deploy-openshift.sh
#
# Required environment variables:
#   NGC_API_KEY     — NGC org key for pulling images from nvcr.io and NIM model downloads.
#                     Get one at https://org.ngc.nvidia.com/setup/api-keys
#   NVIDIA_API_KEY  — build.nvidia.com key for hosted Nemotron inference.
#                     Get one at https://build.nvidia.com (click "Get API Key" on any model page).
#                     If not set, Nemotron will use the local NIM (Llama 8B) instead of hosted 49B.
#   AIRA_NAMESPACE  — OpenShift namespace for the AIRA deployment.
set -euo pipefail

: "${NGC_API_KEY:?Error: NGC_API_KEY is required (get one at https://org.ngc.nvidia.com/setup/api-keys)}"
: "${AIRA_NAMESPACE:?Error: AIRA_NAMESPACE is required}"

# If NVIDIA_API_KEY is not set, fall back to local NIM for Nemotron
NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
if [ -z "$NVIDIA_API_KEY" ]; then
  echo "Note: NVIDIA_API_KEY not set — Nemotron will use the local NIM (Llama 8B)."
  echo "      For hosted Nemotron 49B, set NVIDIA_API_KEY from https://build.nvidia.com"
  NEMOTRON_BASE_URL="http://instruct-llm:8000/v1"
  NEMOTRON_MODEL_NAME="meta/llama-3.1-8b-instruct"
  BACKEND_API_KEY="$NGC_API_KEY"
else
  NEMOTRON_BASE_URL="https://integrate.api.nvidia.com/v1"
  NEMOTRON_MODEL_NAME="nvidia/llama-3.3-nemotron-super-49b-v1.5"
  BACKEND_API_KEY="$NVIDIA_API_KEY"
fi

# Configurable settings
RAG_NAMESPACE="${RAG_NAMESPACE:-${AIRA_NAMESPACE}-rag}"
TAVILY_API_KEY="${TAVILY_API_KEY:-placeholder}"
STORAGE_CLASS="${STORAGE_CLASS:-gp3-csi}"

# GPU tolerations — comma-separated taint keys on your GPU nodes
# Find yours: oc describe node <gpu-node> | grep -A5 Taints
GPU_TOLERATION_KEYS="${GPU_TOLERATION_KEYS:-nvidia.com/gpu}"
GPU_TOLERATION_EFFECT="${GPU_TOLERATION_EFFECT:-NoSchedule}"

# RAG chart source (version-pinned)
RAG_CHART_URL="${RAG_CHART_URL:-https://helm.ngc.nvidia.com/nvidia/blueprint/charts/nvidia-blueprint-rag-v2.3.2.tgz}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AIRA_CHART="$REPO_ROOT/deploy/helm/aiq-aira"

# Parse toleration keys into an array once (used throughout the script)
IFS=',' read -ra TKEYS <<< "$GPU_TOLERATION_KEYS"

echo "=== AIRA OpenShift Deployment ==="
echo "AIRA namespace:    $AIRA_NAMESPACE"
echo "RAG namespace:     $RAG_NAMESPACE"
echo "GPU tolerations:   ${TKEYS[*]}"
echo "Nemotron model:    $NEMOTRON_MODEL_NAME"
echo "Nemotron endpoint: $NEMOTRON_BASE_URL"
echo ""

# ---------------------------------------------------------------
# Helper: patch tolerations onto a deployment after Helm install.
# Helm --set doesn't reliably propagate tolerations through deeply
# nested subcharts (nv-ingest → sub-models). This function patches
# them directly on the Deployment resource.
# ---------------------------------------------------------------
patch_tolerations() {
  local deploy="$1"
  local namespace="$2"

  if ! oc get deployment "$deploy" -n "$namespace" &>/dev/null; then
    return
  fi

  local patches="["
  for key in "${TKEYS[@]}"; do
    patches+='{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"'"$key"'","operator":"Exists","effect":"'"$GPU_TOLERATION_EFFECT"'"}},'
  done
  patches="${patches%,}]"

  # Ensure tolerations array exists before appending
  existing=$(oc get deployment "$deploy" -n "$namespace" -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null)
  if [ -z "$existing" ] || [ "$existing" = "null" ]; then
    oc patch deployment "$deploy" -n "$namespace" --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[]}]' 2>/dev/null || true
  fi

  oc patch deployment "$deploy" -n "$namespace" --type='json' -p="$patches" 2>/dev/null || true
}

# ---------------------------------------------------------------
# PHASE 1: Deploy NVIDIA RAG Blueprint
# ---------------------------------------------------------------
echo "--- Phase 1: NVIDIA RAG Blueprint ---"

# Create namespace
oc get namespace "$RAG_NAMESPACE" &>/dev/null || oc new-project "$RAG_NAMESPACE"

# Grant anyuid SCC to service accounts that need it.
# Bindings are created before Helm so pods are admitted correctly on first try.
echo "Granting anyuid SCC..."
oc adm policy add-scc-to-user anyuid -z default -n "$RAG_NAMESPACE"
oc adm policy add-scc-to-user anyuid -z rag-server -n "$RAG_NAMESPACE"
oc adm policy add-scc-to-user anyuid -z rag-nv-ingest -n "$RAG_NAMESPACE"
oc adm policy add-scc-to-user anyuid -z rag-nv-ingest-ms-runtime -n "$RAG_NAMESPACE" 2>/dev/null || true

# Build GPU toleration --set args for embedding and reranking NIMs.
# These are top-level subcharts where --set tolerations work reliably.
RAG_TOLERATION_ARGS=()
for i in "${!TKEYS[@]}"; do
  key="${TKEYS[$i]}"
  for svc in "nvidia-nim-llama-32-nv-embedqa-1b-v2" "nvidia-nim-llama-32-nv-rerankqa-1b-v2"; do
    RAG_TOLERATION_ARGS+=(
      --set "${svc}.tolerations[${i}].key=${key}"
      --set "${svc}.tolerations[${i}].effect=${GPU_TOLERATION_EFFECT}"
      --set "${svc}.tolerations[${i}].operator=Exists"
    )
  done
done

echo "Installing RAG Blueprint..."
helm upgrade --install rag -n "$RAG_NAMESPACE" \
  "$RAG_CHART_URL" \
  -f "$SCRIPT_DIR/rag-values-openshift.yaml" \
  --set imagePullSecret.password="$NGC_API_KEY" \
  --set ngcApiSecret.password="$NGC_API_KEY" \
  --set "ingestor-server.imagePullSecret.password=$NGC_API_KEY" \
  --set "ingestor-server.persistence.storageClass=$STORAGE_CLASS" \
  "${RAG_TOLERATION_ARGS[@]}"

# Post-deploy patches
echo "Applying post-deploy patches..."
sleep 5

# Milvus works in CPU mode — remove the GPU request
oc patch deployment milvus-standalone -n "$RAG_NAMESPACE" --type='json' \
  -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources/limits/nvidia.com~1gpu"}]' 2>/dev/null || true

# Patch GPU tolerations onto nv-ingest GPU models.
# Helm --set doesn't propagate through the nv-ingest subchart's nested structure,
# so we patch the Deployment resources directly after install.
echo "Patching nv-ingest GPU model tolerations..."
for deploy in nv-ingest-ocr rag-nemoretriever-page-elements-v2 rag-nemoretriever-table-structure-v1 rag-nemoretriever-graphic-elements-v1; do
  patch_tolerations "$deploy" "$RAG_NAMESPACE"
done

# Reduce nv-ingest runtime resources (default 24 CPU / 24Gi is oversized) and add tolerations.
# Without this, the pod stays Pending on clusters with limited CPU/memory on worker nodes.
echo "Patching nv-ingest runtime resources..."
oc patch deployment rag-nv-ingest -n "$RAG_NAMESPACE" --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"2"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"8Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"4"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"16Gi"}
]' 2>/dev/null || true
patch_tolerations "rag-nv-ingest" "$RAG_NAMESPACE"

# Fix embedding NIM tokenizer parallelism bug.
# The HuggingFace tokenizers Rust library panics with "GlobalPoolAlreadyInitialized"
# when concurrent embedding requests trigger simultaneous thread pool initialization.
echo "Patching embedding NIM tokenizer parallelism..."
oc set env deployment/rag-nvidia-nim-llama-32-nv-embedqa-1b-v2 -n "$RAG_NAMESPACE" \
  TOKENIZERS_PARALLELISM=false 2>/dev/null || true

# Reduce nv-ingest concurrency to avoid overwhelming the embedding NIM.
echo "Tuning nv-ingest concurrency..."
oc set env deployment/ingestor-server -n "$RAG_NAMESPACE" \
  NV_INGEST_FILES_PER_BATCH=4 \
  NV_INGEST_CONCURRENT_BATCHES=1 2>/dev/null || true

echo "RAG Blueprint installed."

# ---------------------------------------------------------------
# PHASE 2: Deploy AIRA Blueprint
# ---------------------------------------------------------------
echo ""
echo "--- Phase 2: AIRA Blueprint ---"

# Create namespace
oc get namespace "$AIRA_NAMESPACE" &>/dev/null || oc new-project "$AIRA_NAMESPACE"

# Create secrets with Helm ownership labels so helm upgrade --install can adopt them.
# Without these labels, Helm refuses to install because it sees "unmanaged" secrets
# with the same names that the chart wants to create.
HELM_LABELS='app.kubernetes.io/managed-by=Helm'
HELM_ANN_NAME="meta.helm.sh/release-name=aira"
HELM_ANN_NS="meta.helm.sh/release-namespace=$AIRA_NAMESPACE"

echo "Creating secrets..."
if ! oc get secret ngc-secret -n "$AIRA_NAMESPACE" &>/dev/null; then
  oc create secret docker-registry ngc-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY" \
    -n "$AIRA_NAMESPACE"
  oc label secret ngc-secret $HELM_LABELS -n "$AIRA_NAMESPACE"
  oc annotate secret ngc-secret $HELM_ANN_NAME $HELM_ANN_NS -n "$AIRA_NAMESPACE"
fi

if ! oc get secret ngc-api -n "$AIRA_NAMESPACE" &>/dev/null; then
  oc create secret generic ngc-api \
    --from-literal=NVIDIA_API_KEY="$BACKEND_API_KEY" \
    -n "$AIRA_NAMESPACE"
  oc label secret ngc-api $HELM_LABELS -n "$AIRA_NAMESPACE"
  oc annotate secret ngc-api $HELM_ANN_NAME $HELM_ANN_NS -n "$AIRA_NAMESPACE"
fi

if ! oc get secret tavily-secret -n "$AIRA_NAMESPACE" &>/dev/null; then
  oc create secret generic tavily-secret \
    --from-literal=TAVILY_API_KEY="$TAVILY_API_KEY" \
    -n "$AIRA_NAMESPACE"
  oc label secret tavily-secret $HELM_LABELS -n "$AIRA_NAMESPACE"
  oc annotate secret tavily-secret $HELM_ANN_NAME $HELM_ANN_NS -n "$AIRA_NAMESPACE"
fi

# Grant anyuid SCC (backend uv in /root/.local/bin/)
echo "Granting anyuid SCC..."
oc adm policy add-scc-to-user anyuid -z default -n "$AIRA_NAMESPACE"

# Build GPU toleration args for AIRA's nim-llm subchart
AIRA_TOLERATION_ARGS=()
for i in "${!TKEYS[@]}"; do
  key="${TKEYS[$i]}"
  AIRA_TOLERATION_ARGS+=(
    --set "nim-llm.tolerations[${i}].key=${key}"
    --set "nim-llm.tolerations[${i}].effect=${GPU_TOLERATION_EFFECT}"
    --set "nim-llm.tolerations[${i}].operator=Exists"
  )
done

echo "Installing AIRA Blueprint..."
helm upgrade --install aira "$AIRA_CHART" \
  --namespace "$AIRA_NAMESPACE" \
  -f "$SCRIPT_DIR/values-openshift.yaml" \
  --set "backendEnvVars.RAG_SERVER_URL=http://rag-server.${RAG_NAMESPACE}.svc.cluster.local:8081" \
  --set "backendEnvVars.RAG_INGEST_URL=http://ingestor-server.${RAG_NAMESPACE}.svc.cluster.local:8082" \
  --set "backendEnvVars.NEMOTRON_BASE_URL=$NEMOTRON_BASE_URL" \
  --set "backendEnvVars.NEMOTRON_MODEL_NAME=$NEMOTRON_MODEL_NAME" \
  --set "nim-llm.model.ngcAPIKey=$NGC_API_KEY" \
  "${AIRA_TOLERATION_ARGS[@]}"

# Create OpenShift Routes
echo "Creating Routes..."
oc get route aira-frontend -n "$AIRA_NAMESPACE" &>/dev/null || \
  oc create route edge aira-frontend \
    --service=aira-aira-frontend \
    --port=3000 \
    --insecure-policy=Redirect \
    -n "$AIRA_NAMESPACE"

oc get route aira-phoenix -n "$AIRA_NAMESPACE" &>/dev/null || \
  oc create route edge aira-phoenix \
    --service=aira-phoenix \
    --port=6006 \
    --insecure-policy=Redirect \
    -n "$AIRA_NAMESPACE"

echo "AIRA Blueprint installed."

# ---------------------------------------------------------------
# Wait for rollout
# ---------------------------------------------------------------
echo ""
echo "--- Waiting for all pods to be ready (NIM models may take 5-10 min) ---"

# RAG — skip scaled-down deployments
for resource in $(oc get deploy,statefulset -n "$RAG_NAMESPACE" -o name 2>/dev/null); do
  name="${resource#*/}"
  replicas=$(oc get "$resource" -n "$RAG_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [ "$replicas" = "0" ]; then
    echo "  Skipping $name (scaled to 0)"
    continue
  fi
  echo "  Waiting for $name (rag)..."
  oc rollout status "$resource" -n "$RAG_NAMESPACE" --timeout=30m || \
    echo "  Warning: $name not ready — check: oc logs -f $resource -n $RAG_NAMESPACE"
done

# AIRA (includes StatefulSets for nim-llm)
for resource in $(oc get deploy,statefulset -n "$AIRA_NAMESPACE" -o name 2>/dev/null); do
  name="${resource#*/}"
  echo "  Waiting for $name (aira)..."
  oc rollout status "$resource" -n "$AIRA_NAMESPACE" --timeout=30m || \
    echo "  Warning: $name not ready — check: oc logs -f $resource -n $AIRA_NAMESPACE"
done

# ---------------------------------------------------------------
# Print results
# ---------------------------------------------------------------
FRONTEND_ROUTE=$(oc get route aira-frontend -n "$AIRA_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
PHOENIX_ROUTE=$(oc get route aira-phoenix -n "$AIRA_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)

echo ""
echo "=== Done ==="
echo "AIRA namespace: $AIRA_NAMESPACE"
echo "RAG namespace:  $RAG_NAMESPACE"
echo ""
echo "Pods (AIRA):"
oc get pods -n "$AIRA_NAMESPACE" --no-headers 2>/dev/null | sed 's/^/  /'
echo ""
echo "Pods (RAG):"
oc get pods -n "$RAG_NAMESPACE" --no-headers 2>/dev/null | sed 's/^/  /'
echo ""
[ -n "$FRONTEND_ROUTE" ] && echo "Frontend UI: https://$FRONTEND_ROUTE"
[ -n "$PHOENIX_ROUTE" ]  && echo "Phoenix UI:  https://$PHOENIX_ROUTE"

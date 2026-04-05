#!/bin/bash
# AIRA v2.0 OpenShift Deployment Script
#
# Supports two knowledge modes:
#   KNOWLEDGE_MODE=llamaindex (default) — Self-contained with local ChromaDB, 0 GPUs for AIRA.
#   KNOWLEDGE_MODE=frag — Requires NVIDIA RAG Blueprint with full document processing pipeline.
#
# Usage (LlamaIndex mode — simplest, no GPUs for AIRA):
#   NGC_API_KEY=nvapi-... NVIDIA_API_KEY=nvapi-... AIRA_NAMESPACE=aira \
#     bash openshift/deploy/helm/deploy-openshift.sh
#
# Usage (FRAG mode — full RAG pipeline, 6+ additional GPUs):
#   NGC_API_KEY=nvapi-... NVIDIA_API_KEY=nvapi-... AIRA_NAMESPACE=aira KNOWLEDGE_MODE=frag \
#     bash openshift/deploy/helm/deploy-openshift.sh
#
# Required environment variables:
#   NGC_API_KEY      — NGC org key for pulling images from nvcr.io.
#                      Get one at https://org.ngc.nvidia.com/setup/api-keys
#   NVIDIA_API_KEY   — build.nvidia.com key for hosted NIM inference (all LLMs are cloud-hosted in v2.0).
#                      Get one at https://build.nvidia.com (click "Get API Key" on any model page).
#   AIRA_NAMESPACE   — OpenShift namespace for the AIRA deployment.
#
# Optional environment variables:
#   KNOWLEDGE_MODE       — llamaindex (default) or frag
#   TAVILY_API_KEY       — Tavily API key for web search (default: placeholder)
#   RAG_NAMESPACE        — Namespace for RAG Blueprint (default: ${AIRA_NAMESPACE}-rag, FRAG mode only)
#   STORAGE_CLASS        — StorageClass for PVCs (default: gp3-csi)
#   GPU_TOLERATION_KEYS  — Comma-separated taint keys on GPU nodes (default: nvidia.com/gpu)
#   DB_USER_NAME         — PostgreSQL username (default: aiq)
#   DB_USER_PASSWORD     — PostgreSQL password (default: aiq_dev)
set -euo pipefail

# ---------------------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------------------
: "${NGC_API_KEY:?Error: NGC_API_KEY is required (get one at https://org.ngc.nvidia.com/setup/api-keys)}"
: "${NVIDIA_API_KEY:?Error: NVIDIA_API_KEY is required (get one at https://build.nvidia.com)}"
: "${AIRA_NAMESPACE:?Error: AIRA_NAMESPACE is required}"

# ---------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------
KNOWLEDGE_MODE="${KNOWLEDGE_MODE:-llamaindex}"
TAVILY_API_KEY="${TAVILY_API_KEY:-placeholder}"
STORAGE_CLASS="${STORAGE_CLASS:-gp3-csi}"
DB_USER_NAME="${DB_USER_NAME:-aiq}"
DB_USER_PASSWORD="${DB_USER_PASSWORD:-aiq_dev}"

# FRAG-only settings
RAG_NAMESPACE="${RAG_NAMESPACE:-${AIRA_NAMESPACE}-rag}"
GPU_TOLERATION_KEYS="${GPU_TOLERATION_KEYS:-nvidia.com/gpu}"
GPU_TOLERATION_EFFECT="${GPU_TOLERATION_EFFECT:-NoSchedule}"
RAG_CHART_URL="${RAG_CHART_URL:-https://helm.ngc.nvidia.com/nvidia/blueprint/charts/nvidia-blueprint-rag-v2.3.2.tgz}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AIRA_CHART="$REPO_ROOT/deploy/helm/deployment-k8s"

# Parse GPU toleration keys
IFS=',' read -ra TKEYS <<< "$GPU_TOLERATION_KEYS"

# Determine CONFIG_FILE based on knowledge mode
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  CONFIG_FILE="configs/config_web_frag.yml"
else
  CONFIG_FILE="configs/config_web_default_llamaindex.yml"
fi

echo "=== AIRA v2.0 OpenShift Deployment ==="
echo "Knowledge mode:    $KNOWLEDGE_MODE"
echo "AIRA namespace:    $AIRA_NAMESPACE"
echo "Config file:       $CONFIG_FILE"
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  echo "RAG namespace:     $RAG_NAMESPACE"
  echo "GPU tolerations:   ${TKEYS[*]}"
fi
if [ "$TAVILY_API_KEY" = "placeholder" ]; then
  echo ""
  echo "WARNING: TAVILY_API_KEY is not set — web search will not work."
  echo "         Get a free key at https://tavily.com and export TAVILY_API_KEY before running this script."
fi
echo ""

# ---------------------------------------------------------------
# Helper: patch tolerations onto a deployment (FRAG mode only)
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

  existing=$(oc get deployment "$deploy" -n "$namespace" -o jsonpath='{.spec.template.spec.tolerations}' 2>/dev/null)
  if [ -z "$existing" ] || [ "$existing" = "null" ]; then
    oc patch deployment "$deploy" -n "$namespace" --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/tolerations","value":[]}]' 2>/dev/null || true
  fi

  oc patch deployment "$deploy" -n "$namespace" --type='json' -p="$patches" 2>/dev/null || true
}

# ---------------------------------------------------------------
# PHASE 1 (FRAG mode only): Deploy NVIDIA RAG Blueprint
# ---------------------------------------------------------------
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  echo "--- Phase 1: NVIDIA RAG Blueprint (FRAG mode) ---"

  oc get namespace "$RAG_NAMESPACE" &>/dev/null || oc new-project "$RAG_NAMESPACE"

  echo "Granting anyuid SCC..."
  oc adm policy add-scc-to-user anyuid -z default -n "$RAG_NAMESPACE"
  oc adm policy add-scc-to-user anyuid -z rag-server -n "$RAG_NAMESPACE"
  oc adm policy add-scc-to-user anyuid -z rag-nv-ingest -n "$RAG_NAMESPACE"
  oc adm policy add-scc-to-user anyuid -z rag-nv-ingest-ms-runtime -n "$RAG_NAMESPACE" 2>/dev/null || true

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

  echo "Applying RAG post-deploy patches..."
  sleep 5

  oc patch deployment milvus-standalone -n "$RAG_NAMESPACE" --type='json' \
    -p='[{"op": "remove", "path": "/spec/template/spec/containers/0/resources/limits/nvidia.com~1gpu"}]' 2>/dev/null || true

  echo "Patching nv-ingest GPU model tolerations..."
  for deploy in nv-ingest-ocr rag-nemoretriever-page-elements-v2 rag-nemoretriever-table-structure-v1 rag-nemoretriever-graphic-elements-v1; do
    patch_tolerations "$deploy" "$RAG_NAMESPACE"
  done

  echo "Patching nv-ingest runtime resources..."
  oc patch deployment rag-nv-ingest -n "$RAG_NAMESPACE" --type='json' -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"2"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"8Gi"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"4"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"16Gi"}
  ]' 2>/dev/null || true
  patch_tolerations "rag-nv-ingest" "$RAG_NAMESPACE"

  echo "Patching NIM tokenizer parallelism..."
  oc set env deployment/rag-nvidia-nim-llama-32-nv-embedqa-1b-v2 -n "$RAG_NAMESPACE" \
    TOKENIZERS_PARALLELISM=false 2>/dev/null || true
  oc set env deployment/rag-nvidia-nim-llama-32-nv-rerankqa-1b-v2 -n "$RAG_NAMESPACE" \
    TOKENIZERS_PARALLELISM=false 2>/dev/null || true

  echo "Tuning nv-ingest concurrency..."
  oc set env deployment/ingestor-server -n "$RAG_NAMESPACE" \
    NV_INGEST_FILES_PER_BATCH=4 \
    NV_INGEST_CONCURRENT_BATCHES=1 2>/dev/null || true

  echo "RAG Blueprint installed."
  echo ""
fi

# ---------------------------------------------------------------
# PHASE 2: Deploy AIRA Blueprint
# ---------------------------------------------------------------
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  echo "--- Phase 2: AIRA Blueprint ---"
else
  echo "--- Deploying AIRA Blueprint (LlamaIndex mode) ---"
fi

oc get namespace "$AIRA_NAMESPACE" &>/dev/null || oc new-project "$AIRA_NAMESPACE"

# Helm release name and ownership labels for pre-created secrets.
HELM_RELEASE="aiq"
HELM_LABELS="app.kubernetes.io/managed-by=Helm"
HELM_ANN_NAME="meta.helm.sh/release-name=$HELM_RELEASE"
HELM_ANN_NS="meta.helm.sh/release-namespace=$AIRA_NAMESPACE"

# Grant anyuid SCC to service accounts (chart creates per-app SAs).
# Bindings to non-existent SAs are valid — they take effect once the SA is created.
echo "Granting anyuid SCC..."
oc adm policy add-scc-to-user anyuid -z default -n "$AIRA_NAMESPACE"
oc adm policy add-scc-to-user anyuid -z aiq-backend -n "$AIRA_NAMESPACE"
oc adm policy add-scc-to-user anyuid -z aiq-frontend -n "$AIRA_NAMESPACE"
oc adm policy add-scc-to-user anyuid -z aiq-postgres -n "$AIRA_NAMESPACE"

# Create secrets (delete first to ensure current values are used on re-runs)
echo "Creating secrets..."
oc delete secret ngc-secret -n "$AIRA_NAMESPACE" --ignore-not-found 2>/dev/null
oc create secret docker-registry ngc-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="$NGC_API_KEY" \
  -n "$AIRA_NAMESPACE"
oc label secret ngc-secret $HELM_LABELS -n "$AIRA_NAMESPACE"
oc annotate secret ngc-secret $HELM_ANN_NAME $HELM_ANN_NS -n "$AIRA_NAMESPACE"

oc delete secret aiq-credentials -n "$AIRA_NAMESPACE" --ignore-not-found 2>/dev/null
oc create secret generic aiq-credentials \
  --from-literal=NVIDIA_API_KEY="$NVIDIA_API_KEY" \
  --from-literal=TAVILY_API_KEY="$TAVILY_API_KEY" \
  --from-literal=DB_USER_NAME="$DB_USER_NAME" \
  --from-literal=DB_USER_PASSWORD="$DB_USER_PASSWORD" \
  -n "$AIRA_NAMESPACE"
oc label secret aiq-credentials $HELM_LABELS -n "$AIRA_NAMESPACE"
oc annotate secret aiq-credentials $HELM_ANN_NAME $HELM_ANN_NS -n "$AIRA_NAMESPACE"

# Build Helm --set args for knowledge mode
AIRA_SET_ARGS=(
  --set "aiq.appname=$AIRA_NAMESPACE"
  --set "aiq.apps.backend.env.CONFIG_FILE=$CONFIG_FILE"
)

# For FRAG mode, override RAG URLs to point to the RAG Blueprint namespace
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  AIRA_SET_ARGS+=(
    --set "aiq.apps.backend.env.RAG_SERVER_URL=http://rag-server.${RAG_NAMESPACE}.svc.cluster.local:8081"
    --set "aiq.apps.backend.env.RAG_INGEST_URL=http://ingestor-server.${RAG_NAMESPACE}.svc.cluster.local:8082"
  )
fi

# Rebuild subchart dependency
echo "Building Helm dependencies..."
helm dependency build "$AIRA_CHART" 2>/dev/null || helm dependency update "$AIRA_CHART"

echo "Installing AIRA Blueprint..."
helm upgrade --install "$HELM_RELEASE" "$AIRA_CHART" \
  --namespace "$AIRA_NAMESPACE" \
  -f "$SCRIPT_DIR/values-openshift.yaml" \
  "${AIRA_SET_ARGS[@]}"

# Create OpenShift Routes (the chart has route configs in values but no route template)
echo "Creating Routes..."
oc get route aira-frontend -n "$AIRA_NAMESPACE" &>/dev/null || \
  oc create route edge aira-frontend \
    --service=aiq-frontend \
    --port=3000 \
    --insecure-policy=Redirect \
    -n "$AIRA_NAMESPACE"

echo "AIRA Blueprint installed."

# ---------------------------------------------------------------
# Wait for rollout
# ---------------------------------------------------------------
echo ""
echo "--- Waiting for pods to be ready ---"

if [ "$KNOWLEDGE_MODE" = "frag" ]; then
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
fi

for resource in $(oc get deploy,statefulset -n "$AIRA_NAMESPACE" -o name 2>/dev/null); do
  name="${resource#*/}"
  echo "  Waiting for $name (aira)..."
  oc rollout status "$resource" -n "$AIRA_NAMESPACE" --timeout=10m || \
    echo "  Warning: $name not ready — check: oc logs -f $resource -n $AIRA_NAMESPACE"
done

# ---------------------------------------------------------------
# Print results
# ---------------------------------------------------------------
FRONTEND_ROUTE=$(oc get route aira-frontend -n "$AIRA_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)

echo ""
echo "=== Done ==="
echo "Knowledge mode: $KNOWLEDGE_MODE"
echo "AIRA namespace: $AIRA_NAMESPACE"
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  echo "RAG namespace:  $RAG_NAMESPACE"
fi
echo ""
echo "Pods (AIRA):"
oc get pods -n "$AIRA_NAMESPACE" --no-headers 2>/dev/null | sed 's/^/  /'
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  echo ""
  echo "Pods (RAG):"
  oc get pods -n "$RAG_NAMESPACE" --no-headers 2>/dev/null | sed 's/^/  /'
fi
echo ""
[ -n "$FRONTEND_ROUTE" ] && echo "Frontend UI: https://$FRONTEND_ROUTE"
echo ""
echo "Expected pods (AIRA): aiq-backend, aiq-frontend, aiq-postgres"
if [ "$KNOWLEDGE_MODE" = "frag" ]; then
  echo "Expected pods (RAG):  rag-server, ingestor-server, milvus-standalone, etcd,"
  echo "                      minio, redis, embedding NIM, reranking NIM,"
  echo "                      nv-ingest (runtime + 4 GPU models)"
fi

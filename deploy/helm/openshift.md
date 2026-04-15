# OpenShift Deploy Runbook

## Prerequisites

- **OpenShift** 4.14+ with `oc` CLI configured
- **Helm** 3.x installed
- **NGC API Key** — for pulling container images from `nvcr.io`. Get one at https://org.ngc.nvidia.com/setup/api-keys
- **NVIDIA API Key** — for hosted LLM inference on `integrate.api.nvidia.com`. Get one at https://build.nvidia.com (click "Get API Key" on any model page)
- **Tavily API Key** (optional) — for web search functionality. Get a free key at https://tavily.com. Without it, web search queries will return empty results.

> **Important:** The NGC API Key and NVIDIA API Key are **different keys** from different portals. Using the wrong key for the NGC pull secret will cause `ImagePullBackOff` errors.

## 1. Login to OpenShift cluster

```bash
oc login --token=$OPENSHIFT_TOKEN --server=$OPENSHIFT_CLUSTER_URL
```

## 2. Create namespace

```bash
oc new-project ns-aiq
```

> **Namespace / appname mapping:** The Helm chart derives the target namespace from `aiq.appname` (default: `aiq`) by prefixing `ns-`, resulting in `ns-aiq`. If you use a custom namespace, set `--set aiq.appname=<your-namespace> --set aiq.project.deploymentTarget=kind` at install time so the chart targets your namespace directly.

## 3. Export your API keys

```bash
export NGC_API_KEY="<your NGC org key>"
export NVIDIA_API_KEY="<your build.nvidia.com key>"
export TAVILY_API_KEY="<your Tavily key>"   # optional — web search won't work without it
```

## 4. Deploy the application

The chart creates all required secrets (NGC image pull secret, API keys, DB credentials) automatically from the values you pass. No manual `oc create secret` commands are needed. Database credentials default to `aiq` / `aiq_dev` and can be overridden with `--set aiq.openshift.apiKeys.dbUserName=...` and `--set aiq.openshift.apiKeys.dbUserPassword=...`.

```bash
helm dependency build deploy/helm/deployment-k8s

helm upgrade --install aiq deploy/helm/deployment-k8s \
  -f deploy/helm/deployment-k8s/values-openshift.yaml \
  --set aiq.openshift.ngcSecret.password="$NGC_API_KEY" \
  --set aiq.openshift.apiKeys.nvidiaApiKey="$NVIDIA_API_KEY" \
  --set aiq.openshift.apiKeys.tavilyApiKey="$TAVILY_API_KEY" \
  -n ns-aiq \
  --wait --timeout 10m
```

> For a custom namespace, add: `--set aiq.appname=<your-namespace> --set aiq.project.deploymentTarget=kind`

> **Already have secrets?** If you prefer to create secrets manually before install, just omit the corresponding `--set` flags. On `helm upgrade`, Helm will update the secrets with the latest values.

## 5. Verify the deployment

```bash
# All pods should be Running 1/1
oc get pods -n ns-aiq

# Get the frontend URL
echo "https://$(oc get route aiq-frontend -n ns-aiq -o jsonpath='{.spec.host}')"

# Backend health check
oc exec deploy/aiq-backend -n ns-aiq -- wget -qO- http://localhost:8000/health

# Stream backend logs
oc logs -f deploy/aiq-backend -n ns-aiq -c backend
```

**Expected pods:**

| Pod | Purpose |
|-----|---------|
| `aiq-backend` | Research assistant API (hosted LLMs via integrate.api.nvidia.com) |
| `aiq-frontend` | Web UI |
| `aiq-postgres` | PostgreSQL for job state, checkpoints, and summaries |

## 6. FRAG mode (optional)

The default deployment uses LlamaIndex mode — a self-contained knowledge backend with no GPUs or external services. To use Foundational RAG (FRAG) mode instead, you need a running [NVIDIA RAG Blueprint](https://github.com/NVIDIA-AI-Blueprints/rag) in a separate namespace (requires 6+ GPUs for the embedding, reranking, and LLM NIMs plus nv-ingest).

Deploy the RAG Blueprint first (see the RAG chart's `values-openshift.yaml`), then install AIQ with the FRAG config pointing to its services:

```bash
RAG_NAMESPACE="<namespace where RAG Blueprint is deployed>"

helm upgrade --install aiq deploy/helm/deployment-k8s \
  -f deploy/helm/deployment-k8s/values-openshift.yaml \
  --set aiq.openshift.ngcSecret.password="$NGC_API_KEY" \
  --set aiq.openshift.apiKeys.nvidiaApiKey="$NVIDIA_API_KEY" \
  --set aiq.openshift.apiKeys.tavilyApiKey="$TAVILY_API_KEY" \
  --set aiq.apps.backend.env.CONFIG_FILE=configs/config_web_frag.yml \
  --set aiq.apps.backend.env.RAG_SERVER_URL=http://rag-server.$RAG_NAMESPACE.svc.cluster.local:8081/v1 \
  --set aiq.apps.backend.env.RAG_INGEST_URL=http://ingestor-server.$RAG_NAMESPACE.svc.cluster.local:8082/v1 \
  -n ns-aiq \
  --wait --timeout 10m
```

The only differences from the default install are the three additional `--set` flags that switch the config file and point to the RAG services. Everything else (secrets, Routes, SCC) works identically.

## 7. Uninstall

```bash
helm uninstall aiq -n ns-aiq
oc delete pvc --all -n ns-aiq    # deletes PostgreSQL data
oc delete project ns-aiq
```

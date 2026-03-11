# Deploying NVIDIA AIRA on Red Hat OpenShift AI

This guide covers deploying the [NVIDIA AI-Q Research Assistant (AIRA) v1.2.0](https://github.com/NVIDIA-AI-Blueprints/aiq-aira) blueprint on Red Hat OpenShift AI (RHOAI) using Helm. All OpenShift-specific adaptations are applied at install time by a single deploy script — no manual post-deploy patching is required.

## Table of Contents

- [What We're Deploying](#what-were-deploying)
- [Tested Hardware](#tested-hardware)
- [Prerequisites](#prerequisites)
- [Configuration Reference](#configuration-reference)
- [Deployment](#deployment)
- [Verification](#verification)
- [Accessing the UI](#accessing-the-ui)
- [Document Ingestion](#document-ingestion)
- [What's Modified from Upstream](#whats-modified-from-upstream)
- [OpenShift-Specific Challenges and Solutions](#openshift-specific-challenges-and-solutions)
- [Deployment Files](#deployment-files)

---

## What We're Deploying

AIRA is an on-premise deep research assistant that generates research reports from internal data and web search, with human-in-the-loop review. It combines:

- **Research Agent** (AIRA backend) that plans multi-step research queries, retrieves documents, and synthesizes reports
- **Local LLM** (Llama 3.1 8B via NIM) for instruction-following
- **Hosted LLM** (Nemotron via NVIDIA API) for reasoning
- **RAG pipeline** with vector search (Milvus), embedding (NIM), and reranking (NIM) for document retrieval
- **Document processing** (nv-ingest) with OCR, page layout analysis, and table extraction for rich document ingestion
- **Tracing** via Phoenix (OpenTelemetry) for observability

**Data flow:**

- **Ingest:** documents → ingestor-server → nv-ingest (OCR + layout + tables) → embedding NIM → Milvus
- **Research:** user query → AIRA backend → rag-server (vector search + reranking) → LLM → research report
- **Web search:** AIRA backend → Tavily API → additional context for research

AIRA is **not standalone** — it requires the NVIDIA RAG Blueprint as a dependency. The deployment uses two namespaces:

- **AIRA namespace:** backend, frontend, Phoenix, LLM NIM (4 pods, 1 GPU)
- **RAG namespace:** rag-server, ingestor, nv-ingest runtime, nv-ingest GPU models, NIMs, Milvus, MinIO, etcd, Redis (14 pods, 6 GPUs)

**Component summary:**

| Namespace | Component | Image | GPU | Purpose |
|-----------|-----------|-------|-----|---------|
| AIRA | Backend | `nvcr.io/nvidia/blueprint/aira-backend:v1.2.0` | 0 | Research assistant API |
| AIRA | Frontend | `nvcr.io/nvidia/blueprint/aira-frontend:v1.2.0` | 0 | React web UI |
| AIRA | Phoenix | `arizephoenix/phoenix:latest` | 0 | OpenTelemetry tracing |
| AIRA | LLM NIM | `nvcr.io/nim/meta/llama-3.1-8b-instruct` | **1** | Instruct LLM (local) |
| RAG | RAG Server | `nvcr.io/nvidia/blueprint/rag-server:2.3.0` | 0 | RAG query + generation API |
| RAG | Ingestor | `nvcr.io/nvidia/blueprint/ingestor-server:2.3.0` | 0 | Document upload + indexing |
| RAG | nv-ingest Runtime | nv-ingest container | 0 | Document processing orchestrator |
| RAG | nv-ingest OCR | NeMo Retriever OCR | **1** | Text extraction from scanned documents |
| RAG | nv-ingest Page Elements | NeMo Retriever | **1** | Page layout analysis (headers, columns) |
| RAG | nv-ingest Table Structure | NeMo Retriever | **1** | Table detection and extraction |
| RAG | nv-ingest Graphic Elements | NeMo Retriever | **1** | Chart and diagram detection |
| RAG | Embedding NIM | `nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2` | **1** | Document vector embeddings |
| RAG | Reranking NIM | `nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2` | **1** | Search result reranking |
| RAG | Milvus | `milvusdb/milvus` | 0 | Vector database (CPU mode) |
| RAG | MinIO, Redis, etcd | *(various)* | 0 | Infrastructure services |

**Total: 18 pods, 7 GPUs.**

---

## Tested Hardware

This deployment was validated on the following cluster configuration:

**Cluster:** OpenShift 4.19 on AWS (us-east-2)

### GPU nodes

| Instance Type | GPU | VRAM | vCPU | RAM | Count | Role in AIRA |
|---------------|-----|------|------|-----|-------|--------------|
| `g6e.2xlarge` | 1x NVIDIA L40S | 46 GB | 8 | 61 GiB | 4 | Llama 8B NIM, Reranking NIM, nv-ingest OCR (1 GPU each on 3 of 4 nodes) |
| `p4d.24xlarge` | 8x NVIDIA A100 40GB | 40 GB each | 96 | 1.1 TiB | 1 | Embedding NIM, nv-ingest Page Elements, nv-ingest Table Structure, nv-ingest Graphic Elements (4 of 8 GPUs used) |

### Worker nodes (non-GPU)

| Instance Type | vCPU | RAM | Count | Role in AIRA |
|---------------|------|-----|-------|--------------|
| `m6i.2xlarge` | 8 | 30 GiB | 9 | Backend, frontend, RAG server, ingestor, nv-ingest runtime, Milvus, MinIO, Redis, etcd, Phoenix |

### Minimum hardware for reproduction

Any cluster with the following should work:

- **7 GPUs** with at least **16 GB VRAM** each (NVIDIA A100, A10G, L40S, L4, or H100 all work)
- **~17 CPU cores** and **~86 GiB RAM** across worker nodes for non-GPU pods
- **50 GiB persistent storage** (Milvus vector DB + MinIO object storage + ingestor)
- To run **Nemotron 49B locally** instead of using the hosted API, add **4 more GPUs** with 40+ GB VRAM each

### API keys

This deployment uses **two separate API keys**:

| Key | Source | Used for |
|-----|--------|----------|
| `NGC_API_KEY` | [org.ngc.nvidia.com](https://org.ngc.nvidia.com/setup/api-keys) | Pulling container images from `nvcr.io`, NIM model downloads |
| `NVIDIA_API_KEY` | [build.nvidia.com](https://build.nvidia.com) | Hosted Nemotron 49B inference (reasoning model) |

These are both `nvapi-...` format keys but come from different portals with different entitlements. Standard NGC org keys typically cannot call the hosted inference API — a separate build.nvidia.com key is required. If `NVIDIA_API_KEY` is not provided, the deploy script falls back to using the local Llama 8B NIM for reasoning (lower quality but fully self-contained).

---

### What's different from upstream

A full upstream deployment requires ~16 GPUs. This deployment reduces that to 7 GPUs with the following trade-offs:

| Component | Upstream | This Deployment | Impact |
|-----------|----------|-----------------|--------|
| Instruct LLM | Llama 3.3 70B (2 GPUs) | Llama 3.1 8B (1 GPU) | Lower quality research reports |
| Nemotron reasoning | Local NIM (2+ GPUs) | NVIDIA hosted API | Adds network latency, subject to rate limits |
| RAG LLM | Local NIM (2+ GPUs) | NVIDIA hosted API | Same latency trade-off |
| Milvus | GPU-accelerated | CPU mode | Slower vector search on large collections |
| nv-ingest Nemotron Parse | Enabled (1 GPU) | Disabled | Basic text splitting instead of semantic chunking |
| nv-ingest Audio | Enabled (1 GPU) | Disabled | No audio document support |

---

## Prerequisites

- OpenShift CLI (`oc`) 4.16+ installed and authenticated with cluster-admin privileges
- Helm 3.x installed
- NVIDIA GPU Operator installed on the cluster and `nvidia.com/gpu` resource is allocatable
- NGC API key from [NGC](https://org.ngc.nvidia.com/setup/api-keys) with access to the `nvidia/blueprint` organization (standard keys may only have `nim/` access — see [Challenge 11](#11-ngc-image-pull-entitlements))
- At least **7 available GPUs**
- GPU nodes are ready: `oc get nodes -l nvidia.com/gpu`
- GPU node taint keys identified: `oc describe node <gpu-node> | grep -A5 Taints`

### Resource requirements

| Component | CPU | Memory | GPU | Storage |
|-----------|-----|--------|-----|---------|
| AIRA (backend + frontend + phoenix) | 2 cores | 2 Gi | 0 | — |
| LLM NIM (Llama 3.1 8B) | 2 cores | 16 Gi | **1 GPU** | — |
| RAG (rag-server + ingestor) | 2 cores | 12 Gi | 0 | 50 Gi PVC |
| RAG infrastructure (Milvus, MinIO, Redis, etcd) | 4 cores | 8 Gi | 0 | — |
| nv-ingest runtime | 2 cores | 8 Gi | 0 | — |
| nv-ingest GPU models (OCR, pages, tables, graphics) | 4 cores | 32 Gi | **4 GPUs** | — |
| Embedding NIM | 1 core | 8 Gi | **1 GPU** | — |
| Reranking NIM | 1 core | 8 Gi | **1 GPU** | — |
| **Total** | **~17 cores** | **~86 Gi** | **7 GPUs** | **50 Gi** |

---

## Configuration Reference

All options are set via environment variables before calling the deploy script.

### Required Variables

| Variable | Description |
|----------|-------------|
| `NGC_API_KEY` | NGC API key for image pulls and NIM model downloads ([org.ngc.nvidia.com](https://org.ngc.nvidia.com/setup/api-keys)) |
| `AIRA_NAMESPACE` | Kubernetes namespace for the AIRA deployment |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NVIDIA_API_KEY` | *(not set)* | build.nvidia.com key for hosted Nemotron 49B inference. If not set, Nemotron falls back to the local Llama 8B NIM. See [Tested Hardware > API keys](#api-keys). |
| `RAG_NAMESPACE` | `${AIRA_NAMESPACE}-rag` | Namespace for the RAG Blueprint deployment |
| `TAVILY_API_KEY` | `placeholder` | Tavily API key for web search (optional feature) |
| `STORAGE_CLASS` | `gp3-csi` | StorageClass for persistent volumes |
| `GPU_TOLERATION_KEYS` | `nvidia.com/gpu` | Comma-separated GPU node taint keys |
| `GPU_TOLERATION_EFFECT` | `NoSchedule` | Toleration effect matching the GPU node taint |
| `RAG_CHART_URL` | `https://helm.ngc.nvidia.com/...v2.3.2.tgz` | RAG Blueprint Helm chart URL |

---

## Deployment

```bash
NGC_API_KEY=nvapi-...           \
NVIDIA_API_KEY=nvapi-...        \
AIRA_NAMESPACE=<your-namespace> \
GPU_TOLERATION_KEYS=<taint-key> \
bash deploy/helm/deploy-openshift.sh
```

`NVIDIA_API_KEY` is optional — if omitted, Nemotron reasoning falls back to the local Llama 8B. Replace `GPU_TOLERATION_KEYS` with the actual taint key(s) on your GPU nodes (comma-separated for multiple taints). To find them:

```bash
oc describe node <gpu-node> | grep -A5 Taints
```

The script will:

1. Create the RAG namespace and grant `anyuid` SCC to required service accounts
2. Deploy the NVIDIA RAG Blueprint via Helm with GPU tolerations and resource overrides
3. Patch Milvus to remove its GPU request (CPU mode)
4. Patch nv-ingest GPU models with cluster-specific tolerations (Helm `--set` doesn't propagate through nested subcharts)
5. Reduce nv-ingest runtime resource requests from 24 CPU / 24Gi to 2 CPU / 8Gi
6. Fix embedding NIM tokenizer parallelism bug (`TOKENIZERS_PARALLELISM=false`)
7. Tune nv-ingest ingestion concurrency (batch size 4, concurrency 1)
8. Create the AIRA namespace with NGC image pull, API, and Tavily secrets (labeled for Helm ownership)
9. Grant `anyuid` SCC to the default service account
10. Deploy AIRA via Helm with local LLM NIM, cross-namespace RAG URLs, and GPU tolerations
11. Create OpenShift Routes for the frontend and Phoenix UIs
12. Wait for all Deployments and StatefulSets to be ready (up to 30 min — NIM pods download model weights on first run)

---

## Verification

After the script exits, confirm all pods are running:

```bash
oc get pods -n <aira-namespace>
oc get pods -n <rag-namespace>
```

Expected pods:

**AIRA namespace (4 pods):**
```
aira-aira-backend-xxxx     1/1   Running
aira-aira-frontend-xxxx    1/1   Running
aira-nim-llm-0             1/1   Running
aira-phoenix-xxxx          1/1   Running
```

**RAG namespace (14 pods):**
```
ingestor-server-xxxx                              1/1   Running
milvus-standalone-xxxx                            1/1   Running
nv-ingest-ocr-xxxx                                1/1   Running
rag-etcd-0                                        1/1   Running
rag-minio-xxxx                                    1/1   Running
rag-nemoretriever-graphic-elements-v1-xxxx       1/1   Running
rag-nemoretriever-page-elements-v2-xxxx           1/1   Running
rag-nemoretriever-table-structure-v1-xxxx         1/1   Running
rag-nv-ingest-xxxx                                1/1   Running
rag-nvidia-nim-...-embedqa-xxxx                   1/1   Running
rag-nvidia-nim-...-rerankqa-xxxx                  1/1   Running
rag-redis-master-0                                1/1   Running
rag-redis-replicas-0                              1/1   Running
rag-server-xxxx                                   1/1   Running
```

NIM pods may take 5–10 minutes on first deploy while model weights download.

Test cross-namespace connectivity from the AIRA backend:

```bash
oc exec deployment/aira-aira-backend -n <aira-namespace> -- \
  uv run python -c "
import urllib.request
r = urllib.request.urlopen('http://rag-server.<rag-namespace>.svc.cluster.local:8081/health')
print(f'RAG Server: HTTP {r.status}')
r = urllib.request.urlopen('http://ingestor-server.<rag-namespace>.svc.cluster.local:8082/health')
print(f'Ingestor: HTTP {r.status}')
r = urllib.request.urlopen('http://localhost:3838/aiqhealth')
print(f'AIRA Health: HTTP {r.status}')
"
```

Expected output:

```
RAG Server: HTTP 200
Ingestor: HTTP 200
AIRA Health: HTTP 200
```

---

## Accessing the UI

The deploy script prints the UI URLs at the end of the run:

```
=== Done ===
Frontend UI: https://<route-host>
Phoenix UI:  https://<route-host>
```

Open the frontend URL in a browser. The Phoenix tracing UI shows OpenTelemetry traces for all research requests.

---

## Document Ingestion

AIRA requires documents to be uploaded into collections before it can perform research. The repo includes two sample datasets:

- **Biomedical_Dataset** — Scientific journals on the Cystic Fibrosis CFTR gene (2021–2024)
- **Financial_Dataset** — Financial reports from Apple, Facebook, Google, Meta (2020–2024)

### Upload via the bulk upload utility

First, ensure Git LFS files are pulled (the zip files are LFS-tracked):

```bash
git lfs install
git lfs pull
```

Port-forward the ingestor service and run the upload script:

```bash
oc port-forward -n <rag-namespace> service/ingestor-server 8082:8082 &

cd data
export RAG_INGEST_URL="http://localhost:8082"

uv python install 3.12
uv venv --python 3.12 --python-preference managed
uv run pip install -r requirements.txt
cp files/* .
uv run python zip_to_collection.py
```

This creates document collections from each zip file. Ingestion of the 43-file Biomedical Dataset takes approximately 7 minutes with the full nv-ingest GPU pipeline (OCR, page layout, table structure, chart detection, embedding). The script processes files in batches of 4 sequentially.

### Upload via the frontend UI

Open the frontend, create a new collection, and upload files (max 10 at a time). Supported file types: `.pdf`, `.pptx`, `.txt`, `.md`, `.docx`.

---

## OpenShift-Specific Challenges and Solutions

The upstream AIRA and RAG Blueprint Helm charts target vanilla Kubernetes. Running them on OpenShift requires addressing incompatibilities across security contexts, filesystem permissions, GPU scheduling, networking, and configuration. All fixes are applied at install time by `deploy-openshift.sh` and the values override files.

---

### 1. Security Context Constraints

OpenShift's default `restricted` SCC assigns a random non-root UID to containers. Several images expect to run as root or write to root-owned directories.

**Affected Services:**

- **AIRA backend** — The Dockerfile installs `uv` (Python package manager) to `/root/.local/bin/` and expects root. The random UID cannot access `/root` (mode 700), causing `/entrypoint.sh: exec: uv: Permission denied`.
- **RAG server** — Writes temporary files to `./tmp-data` in the working directory. The random UID does not own this path, causing `PermissionError: [Errno 13] Permission denied: './tmp-data'`.
- **nv-ingest** — Infrastructure components (MinIO, etcd) and the nv-ingest runtime expect specific UIDs.

**Solution:** Grant `anyuid` SCC to affected service accounts before Helm install:

```bash
# AIRA namespace
oc adm policy add-scc-to-user anyuid -z default -n <aira-namespace>

# RAG namespace
oc adm policy add-scc-to-user anyuid -z default -n <rag-namespace>
oc adm policy add-scc-to-user anyuid -z rag-server -n <rag-namespace>
oc adm policy add-scc-to-user anyuid -z rag-nv-ingest -n <rag-namespace>
oc adm policy add-scc-to-user anyuid -z rag-nv-ingest-ms-runtime -n <rag-namespace>
```

> **Production note:** For production, rebuild affected images with non-root user support instead of granting `anyuid`.

---

### 2. Filesystem Permissions — Phoenix

Phoenix tries to create its SQLite database at `/.phoenix` (root of the filesystem), which fails even with `anyuid` because writing to `/` is restricted.

**Error:** `Failed to initialize the working directory at /.phoenix: [Errno 13] Permission denied: '/.phoenix'`

**Solution:** Add the `PHOENIX_WORKING_DIR` environment variable to the Phoenix deployment template, redirecting writes to `/tmp/.phoenix`:

```yaml
env:
  - name: PHOENIX_WORKING_DIR
    value: /tmp/.phoenix
```

This patch is applied in `deploy/helm/aiq-aira/templates/phoenix-tracing.yaml` (already included in this repo).

---

### 3. GPU Node Scheduling

GPU nodes often carry custom `NoSchedule` taints on shared clusters. Without matching tolerations, GPU pods stay `Pending`.

**Affected Services:**

- **LLM NIM** (AIRA) — 1 GPU
- **Embedding NIM** — 1 GPU
- **Reranking NIM** — 1 GPU
- **nv-ingest OCR, Page Elements, Table Structure** — 1 GPU each

**Solution:** The deploy script builds tolerations dynamically from the `GPU_TOLERATION_KEYS` environment variable. For top-level subcharts (NIM models, AIRA nim-llm), tolerations are passed via `--set` at Helm install time. For deeply nested subcharts (nv-ingest GPU models), Helm `--set` doesn't reliably propagate, so the script patches the Deployment resources directly after install:

```bash
oc patch deployment <nv-ingest-model> -n <rag-namespace> --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"<taint>","operator":"Exists","effect":"NoSchedule"}}]'
```

Find your GPU node taints:

```bash
oc get nodes -l nvidia.com/gpu.present=true \
  -o custom-columns='NODE:.metadata.name,TAINTS:.spec.taints[*].key'
```

---

### 4. Service Type — NodePort Unavailable

The upstream chart configures the frontend as `NodePort` on port 30080. OpenShift restricts NodePort ranges and prefers Routes for external access. Additionally, the backend Service template references `type` and `targetPort` values that are undefined in the upstream `values.yaml`, producing invalid YAML.

**Solution:** Override both services to `ClusterIP` and expose via OpenShift Routes:

```yaml
# values-openshift.yaml
service:
  type: ClusterIP
  port: 3838
  targetPort: 3838

frontend:
  service:
    type: ClusterIP
```

```bash
oc create route edge aira-frontend --service=aira-aira-frontend --port=3000
```

> **Note:** The missing `service.type` and `service.targetPort` is an upstream chart bug that affects all platforms, not just OpenShift.

---

### 5. Hosted NIM Configuration Conflict

Setting `AIRA_HOSTED_NIMS=true` instructs the entrypoint to load `/app/configs/hosted-config.yml`. However, the Helm ConfigMap mounts only `config.yml` and `security_config.yml` to `/app/configs`, replacing the entire directory and removing `hosted-config.yml` that was baked into the Docker image.

**Error:** `Error: Invalid value for '--config_file': File '/app/configs/hosted-config.yml' does not exist.`

**Solution:** Set `AIRA_HOSTED_NIMS=false` and configure LLM URLs via environment variables instead. The `config.yml` uses `${INSTRUCT_BASE_URL}` and `${NEMOTRON_BASE_URL}` with env var substitution, so both local and hosted URLs work through the same config file:

```yaml
backendEnvVars:
  AIRA_HOSTED_NIMS: "false"
  INSTRUCT_BASE_URL: "http://instruct-llm:8000/v1"       # local NIM
  NEMOTRON_BASE_URL: "https://integrate.api.nvidia.com/v1" # hosted API
```

---

### 6. NEMOTRON_API_KEY Disabled in Template

The `NEMOTRON_API_KEY` environment variable is commented out in the upstream `templates/deployment.yaml`. Without it, the Nemotron reasoning model cannot authenticate to the NVIDIA hosted API.

**Solution:** Uncomment the `NEMOTRON_API_KEY` block in `deployment.yaml`:

```yaml
- name: NEMOTRON_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.ngcApiSecret.name }}
      key: NVIDIA_API_KEY
```

This patch is applied in `deploy/helm/aiq-aira/templates/deployment.yaml` (already included in this repo).

---

### 7. nv-ingest Infrastructure Coupling

MinIO, Milvus, Redis, and etcd — required by the RAG server and ingestor — are deployed as part of the `nv-ingest` subchart. Disabling `nv-ingest` entirely removes these infrastructure services, causing the RAG server to crash with `MaxRetryError: Failed to resolve 'rag-minio'`.

**Solution:** Keep `nv-ingest.enabled: true` and selectively disable only the GPU models you don't need:

```yaml
nv-ingest:
  enabled: true
  graphic_elements:
    enabled: false
  nemotron_parse:
    enabled: false
  audio:
    enabled: false
  embedqa:
    enabled: false
```

---

### 8. nv-ingest GPU Model Cleanup

Some nv-ingest sub-models ignore the `enabled: false` flag and still create Deployments. These consume GPU requests and block scheduling.

**Solution:** The deploy script scales disabled model deployments to zero after Helm install. For example, if `nemotron_parse` is disabled but its Deployment still appears:

```bash
oc scale deployment rag-nemoretriever-nemotron-parse-v1 --replicas=0 -n <rag-namespace>
```

---

### 9. Milvus GPU Request

The NVIDIA RAG Helm chart configures Milvus with a GPU resource request by default. Milvus works well in CPU mode for moderate-scale deployments.

**Solution:** The deploy script removes the GPU request after Helm install:

```bash
oc patch deployment milvus-standalone -n <rag-namespace> --type='json' \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/nvidia.com~1gpu"}]'
```

---

### 10. Resource Oversizing

Default resource requests in the RAG chart are sized for large production deployments:

- **Ingestor server:** 25 Gi memory request — exceeds available memory on smaller worker nodes, leaving the pod `Pending` with `Insufficient memory`
- **nv-ingest runtime:** 24 CPU / 24 Gi memory request — far exceeds what the orchestrator actually needs, blocking scheduling on most nodes

**Solution:** Reduce in `rag-values-openshift.yaml` (ingestor) and via post-deploy patch (nv-ingest runtime):

```yaml
# rag-values-openshift.yaml
ingestor-server:
  resources:
    limits:
      memory: "8Gi"
    requests:
      memory: "4Gi"
```

```bash
# deploy script post-deploy patch
oc patch deployment rag-nv-ingest --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"2"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"8Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"4"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"16Gi"}
]'
```

---

### 11. NGC Image Pull Entitlements

NGC API keys have per-organization entitlements. Standard keys may have access to `nvcr.io/nim/` images but not `nvcr.io/nvidia/blueprint/` images, resulting in `403 Forbidden` errors during image pull.

**Error:** `Failed to pull image "nvcr.io/nvidia/blueprint/aira-backend:v1.2.0": invalid status code from registry 403 (Forbidden)`

**Solution:** Ensure your NGC API key has access to the `nvidia/blueprint` NGC organization. Verify before deploying:

```bash
skopeo inspect --creds '$oauthtoken:<NGC_API_KEY>' \
  docker://nvcr.io/nvidia/blueprint/aira-backend:v1.2.0
```

If this returns 403, contact your NVIDIA account team or check NGC organization settings.

---

### 12. Helm Secret Ownership Conflict

The AIRA Helm chart expects to manage secrets (`ngc-secret`, `ngc-api`, `tavily-secret`). If the deploy script pre-creates these secrets without Helm metadata, `helm upgrade --install` fails with `invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by"`.

**Solution:** The deploy script labels and annotates pre-created secrets so Helm can adopt them:

```bash
oc label secret ngc-secret app.kubernetes.io/managed-by=Helm
oc annotate secret ngc-secret \
  meta.helm.sh/release-name=aira \
  meta.helm.sh/release-namespace=<aira-namespace>
```

---

### 13. Embedding NIM Tokenizer Concurrency Bug

The HuggingFace `tokenizers` Rust library panics with `PanicException: The global thread pool has not been initialized.: ThreadPoolBuildError { kind: GlobalPoolAlreadyInitialized }` when multiple embedding requests arrive concurrently. This causes the embedding NIM to return HTTP 500 for every request, failing all document ingestion.

**Error:** `Embedding error occurred: Error code: 500 - {'object': 'error', 'message': 'Something went wrong with the request.', 'detail': "Failed to process the request(s) for model ... PanicException: The global thread pool has not been initialized.: ThreadPoolBuildError { kind: GlobalPoolAlreadyInitialized }"}`

**Solution:** Disable tokenizer parallelism and reduce nv-ingest concurrency:

```bash
# Disable tokenizer thread pool (prevents the race condition)
oc set env deployment/rag-nvidia-nim-llama-32-nv-embedqa-1b-v2 TOKENIZERS_PARALLELISM=false

# Reduce batch size to avoid overwhelming the NIM
oc set env deployment/ingestor-server NV_INGEST_FILES_PER_BATCH=4 NV_INGEST_CONCURRENT_BATCHES=1
```

---

### 14. nv-ingest Runtime Memory

The nv-ingest runtime (Ray-based orchestrator) processes documents through multiple GPU model stages. With 43 PDF files and parallel pipeline stages, the default 8 Gi memory limit causes `OutOfMemoryError` from Ray.

**Solution:** Increase memory to 16 Gi:

```bash
oc patch deployment rag-nv-ingest --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"8Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"16Gi"}
]'
```

---

## Cleanup

```bash
# AIRA
oc delete route aira-frontend aira-phoenix -n <aira-namespace>
helm uninstall aira -n <aira-namespace>
oc adm policy remove-scc-from-user anyuid -z default -n <aira-namespace>
oc delete project <aira-namespace>

# RAG
helm uninstall rag -n <rag-namespace>
oc adm policy remove-scc-from-user anyuid -z default -n <rag-namespace>
oc adm policy remove-scc-from-user anyuid -z rag-server -n <rag-namespace>
oc adm policy remove-scc-from-user anyuid -z rag-nv-ingest -n <rag-namespace>
oc adm policy remove-scc-from-user anyuid -z rag-nv-ingest-ms-runtime -n <rag-namespace>
oc delete project <rag-namespace>
```

---

## Deployment Files

All OpenShift customizations are codified in the following files:

- **`deploy/helm/deploy-openshift.sh`** — Main deployment script. Creates both namespaces, secrets, SCCs, deploys RAG and AIRA via Helm, applies all post-deploy patches (Milvus GPU removal, nv-ingest tolerations, nv-ingest resource tuning, embedding NIM tokenizer fix, ingestion concurrency tuning), creates Routes, and waits for rollout.
- **`deploy/helm/values-openshift.yaml`** — AIRA Helm values override. Enables local LLM NIM (Llama 3.1 8B), configures Nemotron via hosted API, fixes service types, points to RAG namespace.
- **`deploy/helm/rag-values-openshift.yaml`** — RAG Blueprint Helm values override. Enables nv-ingest GPU models (OCR, page elements, table structure, graphic elements), disables unused models, reduces memory requests, keeps infrastructure services.
- **`deploy/helm/aiq-aira/`** — Local AIRA Helm chart with two template patches:
  - `templates/deployment.yaml` — Uncommented `NEMOTRON_API_KEY` (Challenge 6)
  - `templates/phoenix-tracing.yaml` — Added `PHOENIX_WORKING_DIR=/tmp/.phoenix` (Challenge 2)

Dynamic values (GPU tolerations, RAG namespace, NGC key, storage class) are passed via `--set` flags in the deploy script. Static structural overrides live in the values files.

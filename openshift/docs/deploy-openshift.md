# Deploying AIRA v2.0 on Red Hat OpenShift AI

This guide walks through deploying the **NVIDIA AI-Q Research Assistant (AIRA) v2.0** blueprint on a Red Hat OpenShift or OpenShift AI (RHOAI) cluster. It covers architecture, hardware requirements, configuration, deployment, verification, and every OpenShift-specific challenge encountered during validation.

All OpenShift-specific files are isolated in the `openshift/` directory — no upstream files are permanently modified. Only `README.md` is updated with a link to this guide.

---

## Table of Contents

1. [What We're Deploying](#1-what-were-deploying)
2. [Tested Hardware](#2-tested-hardware)
3. [What's Different from Upstream](#3-whats-different-from-upstream)
4. [Prerequisites](#4-prerequisites)
5. [Configuration Reference](#5-configuration-reference)
6. [Deployment](#6-deployment)
7. [Verification](#7-verification)
8. [Accessing the UI](#8-accessing-the-ui)
9. [Testing and Data Ingestion](#9-testing-and-data-ingestion)
10. [OpenShift-Specific Challenges and Solutions](#10-openshift-specific-challenges-and-solutions)
11. [Cleanup](#11-cleanup)
12. [Deployment Files](#12-deployment-files)

---

## 1. What We're Deploying

AIRA v2.0 is an enterprise-grade deep-research AI assistant built on the NVIDIA NeMo Agent Toolkit. It provides both quick cited answers and in-depth report-style research, using multiple orchestrated LLM agents (intent classification, clarification, shallow research, deep research) backed by NVIDIA hosted NIM models.

### Component Summary

#### AIRA Pods (both knowledge modes)

| Component | Service Name | Image | GPU | Purpose |
|-----------|-------------|-------|-----|---------|
| Backend API | `aiq-backend` | `nvcr.io/nvidia/blueprint/aiq-agent:2.0.0` | — | FastAPI backend running research agent workflows, job management, checkpoints |
| Frontend UI | `aiq-frontend` | `nvcr.io/nvidia/blueprint/aiq-frontend:2.0.0` | — | Next.js web interface for research queries, document upload, report viewing |
| PostgreSQL | `aiq-postgres` | `bitnami/postgresql:latest` | — | Job state (NAT JobStore), LangGraph checkpoints, document summaries |

#### RAG Blueprint Pods (FRAG mode only)

| Component | Service Name | Image | GPU | Purpose |
|-----------|-------------|-------|-----|---------|
| RAG Server | `rag-server` | `nvcr.io/nvidia/blueprint/rag-server:2.3.0` | — | RAG query endpoint for knowledge retrieval |
| Ingestor Server | `ingestor-server` | `nvcr.io/nvidia/blueprint/ingestor-server:2.3.0` | — | Document ingestion endpoint |
| Embedding NIM | `rag-nvidia-nim-llama-32-nv-embedqa-1b-v2` | `nvcr.io/nim/nvidia/llama-3.2-nv-embedqa-1b-v2` | 1 | Text embedding for vector search |
| Reranking NIM | `rag-nvidia-nim-llama-32-nv-rerankqa-1b-v2` | `nvcr.io/nim/nvidia/llama-3.2-nv-rerankqa-1b-v2` | 1 | Result reranking for relevance |
| nv-ingest OCR | `nv-ingest-ocr` | nv-ingest OCR model | 1 | Optical character recognition from PDFs |
| nv-ingest Page Elements | `rag-nemoretriever-page-elements-v2` | NeMoRetriever model | 1 | Page layout and element extraction |
| nv-ingest Table Structure | `rag-nemoretriever-table-structure-v1` | NeMoRetriever model | 1 | Table detection and extraction |
| nv-ingest Graphic Elements | `rag-nemoretriever-graphic-elements-v1` | NeMoRetriever model | 1 | Chart and figure extraction |
| nv-ingest Runtime | `rag-nv-ingest` | nv-ingest orchestrator | — | Ray-based pipeline orchestrator |
| Milvus | `milvus-standalone` | Milvus vector DB | — | Vector database for embeddings |
| MinIO | `minio` | MinIO object storage | — | Object storage for nv-ingest |
| Redis | `redis` | Redis | — | Message broker for nv-ingest |
| etcd | `etcd` | etcd | — | Milvus metadata store |

### Data Flow

```
User submits research query → Frontend (Next.js)
  → Backend (FastAPI)
    → Intent Classifier (Nemotron Nano 30B, hosted API)
      → Shallow path: Shallow Research Agent (Nemotron Nano 30B)
      → Deep path: Deep Research Agent (GPT-OSS 120B + Nemotron Super)
    → Knowledge Retrieval:
      → LlamaIndex mode: local ChromaDB
      → FRAG mode: RAG Server → Milvus (embedding NIM → reranking NIM)
    → Web Search (Tavily API, optional)
  ← Research report returned to Frontend

Document Ingestion (FRAG mode):
  Upload → Ingestor Server → nv-ingest Runtime
    → OCR → Page Elements → Table Structure → Graphic Elements
    → Embedding NIM → Milvus
```

### Total Resource Count

| Mode | AIRA Pods | RAG Pods | Total Pods | GPUs | Notes |
|------|-----------|----------|------------|------|-------|
| LlamaIndex (default) | 3 | 0 | **3** | **0** | All LLMs cloud-hosted; self-contained |
| FRAG | 3 | ~15 | **~18** | **6** | Full document processing pipeline |

---

## 2. Tested Hardware

### Cluster Configuration

| Node Role | Instance Type | GPU | VRAM | Count |
|-----------|--------------|-----|------|-------|
| GPU Worker | AWS p4d.24xlarge | A100-SXM4-40GB | 40 GB each | 1 (8 GPUs available) |
| CPU Worker | AWS m5.2xlarge | — | — | 3 |
| Control Plane | AWS m5.xlarge | — | — | 3 |

- **OpenShift version**: 4.17
- **GPU Operator**: NVIDIA GPU Operator v24.9+
- **Total GPUs used**: 0 (LlamaIndex mode) or 6 (FRAG mode)

### Minimum Requirements for Reproduction

#### LlamaIndex Mode

- 0 GPUs
- ~3 vCPU, ~6 Gi memory
- 10 Gi disk (PostgreSQL PVC)

#### FRAG Mode (additional)

- 6 GPUs with >= 16 GB VRAM each
- ~30 Gi additional memory for infrastructure pods
- 50 Gi disk for Milvus, MinIO, and nv-ingest caches

### API Keys Required

| Key | Source | Purpose |
|-----|--------|---------|
| `NGC_API_KEY` | [org.ngc.nvidia.com](https://org.ngc.nvidia.com/setup/api-keys) | Pull container images from `nvcr.io` |
| `NVIDIA_API_KEY` | [build.nvidia.com](https://build.nvidia.com) | Hosted LLM inference (Nemotron, GPT-OSS, etc.) |
| `TAVILY_API_KEY` (optional) | [tavily.com](https://tavily.com) | Web search functionality |

---

## 3. What's Different from Upstream

The upstream blueprint deploys on vanilla Kubernetes (Kind or EKS) using Ingress with nginx. This deployment adapts it for OpenShift.

| Area | Upstream (Kubernetes) | OpenShift Deployment | Impact |
|------|----------------------|---------------------|--------|
| File isolation | All files in `deploy/helm/` | OpenShift files in `openshift/` dir | No merge conflicts on upstream sync |
| Namespace naming | `ns-{appname}` convention | Custom namespace via `deploymentTarget: kind` override | Users pick any namespace name |
| External access | Ingress (nginx) | OpenShift Routes (edge TLS) | HTTPS by default; no Ingress controller needed |
| Secrets | Manual `kubectl create secret` | Deploy script creates with Helm ownership labels | Idempotent re-runs; Helm can adopt pre-created secrets |
| Security | Default pod security | `anyuid` SCC grants on per-app service accounts | Required for backend (runs as root) and PostgreSQL |
| Knowledge mode | LlamaIndex only by default | Both LlamaIndex and FRAG via `KNOWLEDGE_MODE` | Single script deploys either mode |
| RAG Blueprint | Separate manual deployment | Integrated into deploy script (FRAG mode) | One command deploys everything |
| GPU scheduling | No tolerations | Auto-patched GPU tolerations via `GPU_TOLERATION_KEYS` | Works on clusters with GPU taints |
| nv-ingest resources | 24 CPU / 24 Gi default | Patched to 2-4 CPU / 8-16 Gi | Fits on typical test clusters |

---

## 4. Prerequisites

### CLI Tools

| Tool | Minimum Version | Install |
|------|----------------|---------|
| `oc` | 4.12+ | [docs.openshift.com](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) |
| `helm` | 3.x | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |

### Cluster Requirements

- OpenShift 4.12+ with authenticated `oc` CLI
- (FRAG mode only) NVIDIA GPU Operator installed and functional
- (FRAG mode only) At least 6 GPUs available

### GPU Availability Check (FRAG mode only)

```bash
# Verify GPU nodes exist
oc get nodes -l nvidia.com/gpu.present=true

# Check GPU allocatable capacity
oc describe node <gpu-node-name> | grep -A5 "Allocatable"

# Check GPU taint keys (needed for GPU_TOLERATION_KEYS)
oc describe node <gpu-node-name> | grep Taints
```

---

## 5. Configuration Reference

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `NGC_API_KEY` | NGC org key for pulling images from `nvcr.io` |
| `NVIDIA_API_KEY` | build.nvidia.com key for hosted NIM inference (all LLMs in v2.0 are cloud-hosted) |
| `AIRA_NAMESPACE` | OpenShift namespace/project for the AIRA deployment |

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KNOWLEDGE_MODE` | `llamaindex` | Knowledge backend: `llamaindex` (self-contained) or `frag` (external RAG Blueprint) |
| `TAVILY_API_KEY` | `placeholder` | Tavily API key for web search. Without a valid key, web search is disabled. |
| `RAG_NAMESPACE` | `${AIRA_NAMESPACE}-rag` | Namespace for RAG Blueprint (FRAG mode only) |
| `STORAGE_CLASS` | `gp3-csi` | StorageClass for PVCs |
| `GPU_TOLERATION_KEYS` | `nvidia.com/gpu` | Comma-separated taint keys on GPU nodes (FRAG mode only) |
| `GPU_TOLERATION_EFFECT` | `NoSchedule` | Toleration effect for GPU taints |
| `DB_USER_NAME` | `aiq` | PostgreSQL username |
| `DB_USER_PASSWORD` | `aiq_dev` | PostgreSQL password |
| `RAG_CHART_URL` | `https://helm.ngc.nvidia.com/.../nvidia-blueprint-rag-v2.3.2.tgz` | RAG Blueprint Helm chart URL (FRAG mode only) |

---

## 6. Deployment

### Single Command (LlamaIndex Mode — 0 GPUs)

```bash
NGC_API_KEY=nvapi-...      \
NVIDIA_API_KEY=nvapi-...   \
AIRA_NAMESPACE=aira        \
bash openshift/deploy/helm/deploy-openshift.sh
```

### Single Command (FRAG Mode — 6 GPUs)

```bash
NGC_API_KEY=nvapi-...      \
NVIDIA_API_KEY=nvapi-...   \
AIRA_NAMESPACE=aira        \
KNOWLEDGE_MODE=frag        \
bash openshift/deploy/helm/deploy-openshift.sh
```

### What the Script Does

The deploy script executes these phases:

1. **Validate inputs** — Checks required environment variables are set.

2. **(FRAG only) Phase 1: RAG Blueprint** — Creates the RAG namespace, grants `anyuid` SCC, installs the RAG Blueprint Helm chart with GPU tolerations and NIM configurations, then applies post-deploy patches for resource tuning, tokenizer bug workaround, and concurrency limits.

3. **Phase 2: AIRA Blueprint** — Creates the AIRA namespace, grants `anyuid` SCC to all service accounts (`default`, `aiq-backend`, `aiq-frontend`, `aiq-postgres`), creates `ngc-secret` (image pull) and `aiq-credentials` (API keys, DB credentials) with Helm ownership labels.

4. **Helm install** — Builds subchart dependencies and runs `helm upgrade --install` with OpenShift values and dynamic `--set` arguments for the selected knowledge mode and namespace.

5. **Routes** — Creates an OpenShift Route (edge TLS) for the frontend.

6. **Rollout wait** — Waits for all deployments to become ready, printing status as each pod starts.

---

## 7. Verification

### Check All Pods

```bash
# AIRA pods (both modes)
oc get pods -n $AIRA_NAMESPACE

# Expected: aiq-backend, aiq-frontend, aiq-postgres — all Running
```

```bash
# RAG pods (FRAG mode only)
oc get pods -n ${AIRA_NAMESPACE}-rag
```

### Health Check

```bash
oc port-forward svc/aiq-backend 8000:8000 -n $AIRA_NAMESPACE &
curl http://localhost:8000/health
```

### Check Routes

```bash
oc get routes -n $AIRA_NAMESPACE
```

---

## 8. Accessing the UI

```bash
FRONTEND=$(oc get route aira-frontend -n $AIRA_NAMESPACE -o jsonpath='{.spec.host}')
echo "https://$FRONTEND"
```

Open the URL in your browser. The AIRA research interface allows you to:
- Ask research questions (shallow or deep research)
- Upload documents for knowledge retrieval
- View generated research reports with citations
- Track async deep research jobs

---

## 9. Testing and Data Ingestion

Pods being `Running` does not mean the pipeline works end-to-end. This section validates actual functionality.

### LlamaIndex Mode

In LlamaIndex mode, documents are uploaded directly through the frontend UI:

1. Open the frontend URL (from the Route).
2. Use the file upload feature to add documents (PDF, DOCX, TXT, MD — up to 100 MB, 10 files).
3. Documents are processed and stored in the local ChromaDB vector store.
4. Ask questions about the uploaded content — the agent should retrieve relevant passages.

> **Note**: In LlamaIndex mode, uploaded data is stored inside the backend pod's filesystem at `/app/data/chroma`. Data is lost if the pod restarts unless you configure a PersistentVolumeClaim for that path.

### FRAG Mode

In FRAG mode, documents go through the full nv-ingest pipeline (OCR, page elements, table structure, graphic elements, embedding) before being stored in Milvus.

#### Bulk Upload via Script

```bash
# Port-forward to the ingestor service
oc port-forward svc/ingestor-server 8082:8082 -n ${AIRA_NAMESPACE}-rag &

# Install dependencies (if needed)
pip install aiohttp pymilvus

# Run the upload script
RAG_INGEST_URL="http://localhost:8082" python data/zip_to_collection.py \
  --zip_path data/Biomedical_Dataset.zip \
  --collection_name biomedical
```

#### Frontend Upload

Use the web UI file upload — files are routed to the ingestor server automatically.

#### Verify Ingestion

```bash
oc port-forward svc/milvus 19530:19530 -n ${AIRA_NAMESPACE}-rag &
python -c "
from pymilvus import connections, Collection
connections.connect(host='localhost', port='19530')
c = Collection('biomedical')
print(f'Documents: {c.num_entities}')
"
```

#### End-to-End Test

1. Open the frontend.
2. Ask a question about the ingested documents (e.g., "What are the key findings about biomedical imaging?").
3. The agent should retrieve relevant passages from the ingested collection and produce a cited answer.

---

## 10. OpenShift-Specific Challenges and Solutions

### Challenge 1: Namespace Naming Convention

**Problem**: The v2.0 Helm chart hardcodes namespace as `ns-{appname}` via the `aiq.namespace` helper. This doesn't align with OpenShift's custom namespace naming.

**Error**: Resources created in `ns-aiq` instead of the intended namespace.

**Affected**: All resources (Deployments, Services, PVCs, ConfigMaps).

**Fix**: Set `project.deploymentTarget: kind` in `values-openshift.yaml`, which makes `aiq.namespace` return `appname` directly. The deploy script overrides `aiq.appname` via `--set` to match the target namespace.

### Challenge 2: No Route Template in Chart

**Problem**: The chart defines `route` configs in values (host, TLS, annotations) but has no `route.yaml` template — only Kubernetes Ingress is supported.

**Error**: No Route created after `helm install`; frontend not externally accessible.

**Affected**: Frontend service.

**Fix**: The deploy script creates OpenShift Routes manually via `oc create route edge` after Helm install.

### Challenge 3: Security Context Constraints (SCCs)

**Problem**: OpenShift's default restricted SCC blocks pods that run as root or specific UIDs. The backend image runs processes as root, and PostgreSQL (bitnami) needs UID 1001 with specific filesystem permissions.

**Error**: `CrashLoopBackOff` — containers fail to start due to permission denied errors.

**Affected**: `aiq-backend`, `aiq-postgres`.

**Fix**: Grant `anyuid` SCC to all app-specific service accounts (`aiq-backend`, `aiq-frontend`, `aiq-postgres`, `default`) **before** Helm install. SCC bindings to non-existent SAs are valid in OpenShift — they take effect once the chart creates them.

### Challenge 4: Secret Helm Ownership for Idempotent Re-runs

**Problem**: `helm upgrade --install` fails with "cannot patch secret — field manager conflict" when it encounters secrets created outside of Helm.

**Error**: `Error: UPGRADE FAILED: cannot patch "aiq-credentials" with kind Secret`.

**Affected**: `ngc-secret`, `aiq-credentials`.

**Fix**: Secrets are labeled with `app.kubernetes.io/managed-by=Helm` and annotated with `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace`. Additionally, the deploy script deletes and recreates secrets on each run to ensure current values are used.

### Challenge 5: FRAG Mode — GPU Tolerations Don't Propagate

**Problem**: The RAG Blueprint's nv-ingest GPU models are deeply nested subcharts. Helm `--set tolerations` at the top level doesn't propagate through nested subchart values.

**Error**: GPU pods stuck in `Pending` — no node matches the pod's `nodeSelector` / tolerations.

**Affected**: nv-ingest OCR, Page Elements, Table Structure, Graphic Elements, nv-ingest Runtime.

**Fix**: The deploy script patches tolerations directly onto Deployment resources via `oc patch` after `helm install`.

### Challenge 6: FRAG Mode — nv-ingest Resource Oversizing

**Problem**: The nv-ingest runtime requests 24 CPU / 24 Gi memory by default, which exceeds available resources on most test clusters.

**Error**: `rag-nv-ingest` pod stuck in `Pending` — insufficient CPU/memory.

**Affected**: `rag-nv-ingest` deployment.

**Fix**: The deploy script patches resources to 2-4 CPU / 8-16 Gi via `oc patch`.

### Challenge 7: FRAG Mode — NIM Tokenizer Parallelism Bug

**Problem**: HuggingFace tokenizers Rust library panics with `GlobalPoolAlreadyInitialized` when the rayon thread pool initialization races during Triton model loading.

**Error**: Embedding and reranking NIMs crash during startup or fail readiness probes intermittently.

**Affected**: `rag-nvidia-nim-llama-32-nv-embedqa-1b-v2`, `rag-nvidia-nim-llama-32-nv-rerankqa-1b-v2`.

**Fix**: Set `TOKENIZERS_PARALLELISM=false` via `oc set env` on both NIM deployments.

---

## 11. Cleanup

```bash
# Uninstall AIRA
helm uninstall aiq -n $AIRA_NAMESPACE
oc delete project $AIRA_NAMESPACE

# Uninstall RAG (FRAG mode only)
helm uninstall rag -n ${AIRA_NAMESPACE}-rag
oc delete project ${AIRA_NAMESPACE}-rag
```

### Scale Down (preserve data, free GPUs temporarily)

```bash
# AIRA
oc scale deploy/aiq-backend deploy/aiq-frontend deploy/aiq-postgres --replicas=0 -n $AIRA_NAMESPACE

# RAG (FRAG mode only)
oc scale deploy --all --replicas=0 -n ${AIRA_NAMESPACE}-rag
oc scale statefulset --all --replicas=0 -n ${AIRA_NAMESPACE}-rag
```

### Scale Up

```bash
# AIRA
oc scale deploy/aiq-backend deploy/aiq-frontend deploy/aiq-postgres --replicas=1 -n $AIRA_NAMESPACE

# RAG (FRAG mode only) — infrastructure first, then NIMs
oc scale statefulset --all --replicas=1 -n ${AIRA_NAMESPACE}-rag
oc scale deploy --all --replicas=1 -n ${AIRA_NAMESPACE}-rag
```

---

## 12. Deployment Files

All OpenShift-specific files are isolated in the `openshift/` directory. No upstream files are permanently modified (only `README.md` is updated with a link to this guide).

```
openshift/
├── docs/
│   └── deploy-openshift.md              # This guide
└── deploy/helm/
    ├── deploy-openshift.sh               # Automated deployment script (both knowledge modes)
    ├── values-openshift.yaml             # AIRA Helm value overrides for OpenShift
    └── rag-values-openshift.yaml         # RAG Blueprint value overrides (FRAG mode only)
```

### What Each File Does

| File | Purpose |
|------|---------|
| `deploy-openshift.sh` | Single idempotent script that deploys AIRA (and optionally RAG Blueprint). Handles namespace creation, SCC grants, secret management, Helm install, Route creation, and rollout wait. |
| `values-openshift.yaml` | Overrides the upstream Helm chart for OpenShift: sets image repositories/tags, disables Ingress (Routes used instead), configures namespace mapping, and sets image pull secrets. |
| `rag-values-openshift.yaml` | Overrides the RAG Blueprint chart for OpenShift: enables nv-ingest GPU models (OCR, page elements, table structure, graphic elements), disables unused components (observability stack, RAG frontend, RAG LLM). |

### Why No `patches/` Directory

Unlike v1.2, AIRA v2.0 uses a generic Helm chart (`deployment-k8s`) that doesn't require upstream template modifications. All OpenShift adaptations are handled through value overrides and post-deploy patches in the script. No upstream files need to be temporarily modified during `helm install`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ImagePullBackOff` | Missing or invalid `ngc-secret` | Verify `NGC_API_KEY` and re-run the deploy script |
| `CrashLoopBackOff` on backend | Missing `aiq-credentials` secret or invalid API key | Check `oc logs` and verify secret keys |
| `CreateContainerConfigError` | Secret referenced in `envFrom` doesn't exist | Ensure deploy script created `aiq-credentials` before Helm install |
| `Pending` pods (FRAG mode) | Insufficient GPU or CPU resources | Check `oc describe pod` for scheduling errors; verify GPU availability |
| Frontend shows "Network Error" | Backend not ready or API key invalid | Wait for backend pod to be Running; check backend logs |
| FRAG: RAG queries return empty | Documents not ingested or Milvus not ready | Verify ingestion (see [Testing section](#9-testing-and-data-ingestion)) |
| FRAG: Ingestion timeout | nv-ingest models still loading | Wait for all GPU pods in RAG namespace to be Running (5-10 min) |

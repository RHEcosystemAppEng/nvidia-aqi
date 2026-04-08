# OpenShift Deploy Runbook

1. Login to OpenShift cluster

> oc login --token=$OPENSHIFT_TOKEN --server$OPENSHIFT_CLUSTER_URL

2. Create namespace

> oc new-project ns-aiq

3. Create secrets

Make sure you have `NGC_API_KEY` and `NVIDIA_API_KEY` exported in your shell before running these:

```bash
oc create secret docker-registry ngc-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="$NGC_API_KEY" \
  -n ns-aiq

oc create secret generic aiq-credentials \
  --from-literal=NVIDIA_API_KEY="$NVIDIA_API_KEY" \
  --from-literal=TAVILY_API_KEY="${TAVILY_API_KEY:-placeholder}" \
  --from-literal=DB_USER_NAME="aiq" \
  --from-literal=DB_USER_PASSWORD="aiq_dev" \
  -n ns-aiq
```

4. Deploy the application

```bash
helm dependency build deploy/helm/deployment-k8s

helm upgrade --install aiq deploy/helm/deployment-k8s \
  -f deploy/helm/deployment-k8s/values-openshift.yaml \
  -n ns-aiq \
  --wait --timeout 10m
```

5. Verifying everything is healthy

```bash
oc get pods -n ns-aiq

oc get route -n ns-aiq

oc logs -f deployments/aiq-backend
```
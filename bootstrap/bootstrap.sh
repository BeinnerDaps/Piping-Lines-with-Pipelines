#!/bin/bash
set -e

# Default to 'dev' if no argument is passed
ENV=${1:-dev}
APP_NAME="${2:-task-app-${ENV}}"
NAMESPACE="${APP_NAME}"
CLUSTER_NAME="${APP_NAME}-cluster"

BASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CONFIG="${BASH_DIR}/manifests/kind-config.yaml"
ARGO_CONFIG="${BASH_DIR}/manifests/argo-params.yaml"
GTWY_CONFIG="${BASH_DIR}/manifests/envoy-gateway.yaml"
_MASTER_KEY="${BASH_DIR}/manifests/.master-sealed-secret-key.yaml"

TASK_APP_PATH="${BASH_DIR}/../argocd/task-app/${APP_NAME}.yaml"

echo "[*] Starting bootstrap process for $CLUSTER_NAME..."
# 1. Create Kind cluster
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    echo "[+] Cluster $CLUSTER_NAME already exists."
    NEW_CLUSTER=false
else
    echo "[~] Creating Kind cluster..."
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
    NEW_CLUSTER=true
fi

# Key Restoration (Pre-controller Deployment)
if [ -f "$_MASTER_KEY" ]; then
  echo "[+] Restoring master encryption key into cluster..."
  kubectl apply -f "$_MASTER_KEY" --server-side --force-conflicts
else
  echo "[!] No local master key found. Sealed Secrets will generate a new pair."
fi

# 2. Install/Upgrade Gateway API CRDs & Envoy Gateway Controller
if [ "$NEW_CLUSTER" = "true" ] || ! kubectl get ns envoy-gateway-system &>/dev/null; then
  echo "[~] Installing Gateway API CRDs & Envoy Gateway..."
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.9.0 \
    -n envoy-gateway-system \
    --create-namespace \
    --timeout 15m \
    --wait

  echo "[~] Waiting for Envoy Gateway CRDs to be established..."
  kubectl wait --for=condition=Established \
    crd/envoyproxies.gateway.envoyproxy.io \
    crd/gateways.gateway.networking.k8s.io \
    --timeout=60s

  echo "[~] Waiting for Envoy Gateway deployment..."
  kubectl wait deployment/envoy-gateway \
    --namespace envoy-gateway-system \
    --for=condition=available \
    --timeout=180s 
else
  echo "[+] Envoy Gateway already installed. Skipping Helm step."
fi
  
# 3. Install/Upgrade ArgoCD and Image Updater
if [ "$NEW_CLUSTER" = "true" ] || ! kubectl get ns argocd &>/dev/null; then
  echo "[~] Installing ArgoCD..."
  helm repo add argo https://argoproj.github.io/argo-helm --force-update
  helm repo update
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --timeout 15m \
    -f "$ARGO_CONFIG" \
    --wait

  echo "[~] Installing ArgoCD Image Updater..."
  helm upgrade --install argocd-image-updater argo/argocd-image-updater \
    --namespace argocd \
    --timeout 15m \
    --wait

  echo "[~] Waiting for ArgoCD control plane..."
  kubectl wait deployment \
    --namespace argocd \
    --for=condition=available \
    --timeout=600s \
    -l app.kubernetes.io/part-of=argocd
else
  echo "[+] ArgoCD already installed. Skipping Helm step."
fi

# 4. Install/Upgrade Sealed Secrets Controller
if [ "$NEW_CLUSTER" = "true" ] || ! kubectl get ns kube-system &>/dev/null; then
  echo "[~] Setting up Sealed Secrets..."
  helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
  helm repo update

  echo "[~] Installing Sealed Secrets..."
  helm upgrade --install sealed-secrets bitnami/sealed-secrets \
    --namespace kube-system \
    --create-namespace \
    --timeout 15m \
    --wait
    
  echo "[~] Waiting for Sealed Secrets controller..."
  kubectl wait deployment \
    --namespace kube-system \
    --for=condition=available \
    --timeout=120s \
    -l app.kubernetes.io/name=sealed-secrets
else
  echo "[+] Sealed Secrets already installed. Skipping Helm step."
fi

# Backup master key if it wasn't already present
# If no key existed locally, wait for Sealed Secrets controller to generate one, then back it up
if [ ! -f "$_MASTER_KEY" ]; then
  echo "[~] Waiting for Sealed Secrets controller to initialize key pair..."
  kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=60s 2>/dev/null || true

  echo "[+] Exporting new master encryption key to $_MASTER_KEY..."
  kubectl get secret -n kube-system \
    -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o yaml | sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d; /managedFields:/d' > "$_MASTER_KEY"
fi
  
# 5. Apply Cluster Infrastructure (Gateway, Repository Secrets, and Argo App)
echo "[~] Applying Envoy-Gateway manifest..."
kubectl apply -f $GTWY_CONFIG

echo "[~] Applying Argocd manifests..."
kubectl apply -f $BASH_DIR/../argocd/infrastructure

echo "[~] Applying Observability manifests (Grafana, Prometheus, Alloy, Loki, Tempo)..."
kubectl apply -f $BASH_DIR/../argocd/observability

echo "[~] Applying $ENV ArgoCD Application..."
if [ -f "$TASK_APP_PATH" ]; then
  kubectl apply -f "$TASK_APP_PATH"
else
  echo "[!] Error: Environment file '$TASK_APP_PATH' not found!"
  exit 1
fi

# Full refresh, Sync, and Forced Rolling Restart
echo "[~] Refreshing ArgoCD application $APP_NAME."
kubectl annotate application ${APP_NAME} -n argocd argocd.argoproj.io/refresh=normal --overwrite || true
sleep 10

# Force Kubernetes to perform a rolling restart of ALL deployments in the namespace to immediately apply the fresh state
echo "[~] Triggering rolling restart for all deployments in namespace ${APP_NAME}..."
kubectl rollout restart deployment -n ${APP_NAME}

# Loop through and wait for every deployment in the namespace to finish rolling out
for deployment in $(kubectl get deployments -n ${APP_NAME} -o name); do
  echo "[~] Waiting for $deployment to complete..."
  kubectl rollout status $deployment -n ${APP_NAME}
done

echo ""
echo "==================================================================="
echo "[+] Bootstrap Complete for $CLUSTER_NAME!"
echo "Access Task-App-Dev: http://localhost:8080"
echo "Access Task-App-Prod: http://localhost:8090"
echo "Access ArgoCD: http://localhost:8081"
echo "Access Grafana: http://localhost:8082"
echo "ArgoCD admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
echo "Pause cluster: docker stop $(docker ps -q --filter label=io.x-k8s.kind.cluster=task-app-dev-cluster)"
echo "Resume cluster: docker start $(docker ps -a -q --filter label=io.x-k8s.kind.cluster=task-app-dev-cluster)"
echo "==================================================================="
#!/bin/bash
set -e

# Usage: ./bootstrap-aws.sh <cluster-name> <aws-region>
ENV=${1:-aws}
APP_NAME="${2:-task-app-${ENV}}"
CLUSTER_NAME="${3:-task-app-demo}"
AWS_REGION="${4:-ap-southeast-1}"

BASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGO_CONFIG="${BASH_DIR}/manifests/argo-params.yaml"
GTWY_CONFIG="${BASH_DIR}/manifests/envoy-gateway.yaml"
STORAGECLASS="${BASH_DIR}/manifests/ebs-storageclass.yaml"
_MASTER_KEY="${BASH_DIR}/manifests/.master-sealed-secret-key.yaml"

TASK_APP_PATH="${BASH_DIR}/../argocd/task-app/${APP_NAME}.yaml"

echo "[*] Pointing kubectl at EKS cluster $CLUSTER_NAME in $AWS_REGION..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

# if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
#   echo "[*] Cluster is already bootstrapped (ArgoCD found). Skipping base installation..."
# else
#   echo "[*] First-time setup detected. Bootstrapping cluster..."
  
echo "[~] Applying gp3 StorageClass (EBS CSI)..."
kubectl apply -f "$STORAGECLASS"

# Key Restoration (Pre-controller Deployment) — reuse the same master key
# your kind cluster uses, so existing SealedSecrets still decrypt here.
if [ -n "$SEALED_SECRET_MASTER_KEY_FILE" ] && [ -f "$SEALED_SECRET_MASTER_KEY_FILE" ]; then
  echo "[+] Restoring master encryption key from GitLab CI File variable..."
  kubectl create ns kube-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$SEALED_SECRET_MASTER_KEY_FILE" --server-side --force-conflicts
elif [ -f "$_MASTER_KEY" ]; then
  echo "[+] Restoring master encryption key into cluster..."
  kubectl create ns kube-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$_MASTER_KEY" --server-side --force-conflicts
else
  echo "[!] No local master key found — SealedSecrets encrypted for kind won't decrypt here."
  echo "[!] Either copy manifests/.master-sealed-secret-key.yaml from your kind setup,"
  echo "    or re-seal your secrets against this cluster's new key once it generates one."
fi

echo "[~] Installing Gateway API CRDs & Envoy Gateway..."
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.0 \
  -n envoy-gateway-system \
  --create-namespace \
  --wait

kubectl wait --for=condition=Established \
  crd/envoyproxies.gateway.envoyproxy.io \
  crd/gateways.gateway.networking.k8s.io \
  --timeout=60s

kubectl wait deployment/envoy-gateway \
  --namespace envoy-gateway-system \
  --for=condition=available \
  --timeout=180s

echo "[~] Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --timeout 15m \
  -f "$ARGO_CONFIG" \
  --wait

kubectl wait deployment \
  --namespace argocd \
  --for=condition=available \
  --timeout=600s \
  -l app.kubernetes.io/part-of=argocd

echo "[~] Installing Sealed Secrets..."
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm repo update
helm upgrade --install sealed-secrets bitnami/sealed-secrets \
  --namespace kube-system \
  --create-namespace \
  --wait

kubectl wait deployment \
  --namespace kube-system \
  --for=condition=available \
  --timeout=120s \
  -l app.kubernetes.io/name=sealed-secrets

echo "[~] Applying Envoy Gateway manifest..."
kubectl apply -f "$GTWY_CONFIG"

echo "[~] Applying ArgoCD infrastructure + observability manifests..."
kubectl apply -f "$BASH_DIR/../argocd/infrastructure"
kubectl apply -f "$BASH_DIR/../argocd/observability"
# fi

echo "[~] Applying $APP_NAME ArgoCD Application..."
if [ -f "$TASK_APP_PATH" ]; then
  kubectl apply -f "$TASK_APP_PATH"
else
  echo "[!] Error: $TASK_APP_PATH not found!"
  exit 1
fi

kubectl annotate application "$APP_NAME" -n argocd argocd.argoproj.io/refresh=normal --overwrite || true

echo "[*] Waiting for AWS to provision the LoadBalancer DNS..."
# Loop until the Gateway address is populated
LB_HOSTNAME=""
while [ -z "$LB_HOSTNAME" ]; do
  sleep 10
  echo "    ...still waiting for AWS..."
  # This extracts the address value from the first Gateway it finds across all namespaces
  LB_HOSTNAME=$(kubectl get gateway -A -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || echo "")
done

echo ""
echo "==================================================================="
echo "🚀 DEPLOYMENT SUCCESSFUL!"
echo "🌐 Your Gateway URL is: http://${LB_HOSTNAME}"
echo "==================================================================="

#!/bin/bash
set -e

ENV="${1:-dev}"
APP_NAME="${2:-task-app-${ENV}}"
CLUSTER_NAME="${3:-${APP_NAME}-cluster}"

BASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MASTER_KEY="${BASH_DIR}/manifests/.master-sealed-secret-key.yaml"

echo "[*] Starting teardown process for $CLUSTER_NAME..."
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    # 1. Back up active key before cluster deletion
    if kubectl get ns kube-system &>/dev/null; then
        echo "[~] Exporting latest master encryption key backup..."
        kubectl get secret -n kube-system \
            -l sealedsecrets.bitnami.com/sealed-secrets-key \
            -o yaml | sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d; /managedFields:/d' > "$_MASTER_KEY"
        echo "[+] Exported the master encryption key to $_MASTER_KEY..."
    fi
    # 2. Delete cluster
    echo "[~] Deleting Kind cluster $CLUSTER_NAME..."
    kind delete cluster --name "$CLUSTER_NAME"
    echo "[-] Cluster $CLUSTER_NAME deleted successfully."
else
    echo "[!] Cluster $CLUSTER_NAME does not exist. Skipping cluster deletion."
fi

echo "[*] Teardown Complete!"
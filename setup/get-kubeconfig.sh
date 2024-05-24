#!/bin/bash

### Source: https://github.com/gravitational/teleport/blob/master/examples/gke-auth/

# This script receives a new set of credentials for the auth server
# that are based on TLS client certificates. This is better than using
# cloud provider specific auth "plugins" because it works on any cluster
# and does not require any extra binaries. It produces kubeconfig to build/kubeconfig

# Produce CSR request first

set -eu -o pipefail

# Set OS specific values.
if [[ "$OSTYPE" == "linux-gnu" ]]; then
    REQUEST_ID=$(uuid)
    BASE64_DECODE_FLAG="-d"
    BASE64_WRAP_FLAG="-w 0"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    REQUEST_ID=$(uuidgen)
    BASE64_DECODE_FLAG="-D"
    BASE64_WRAP_FLAG=""
else
    echo "Unknown OS ${OSTYPE}"
    exit 1
fi

# Install cfssl and cfssljson if not already installed
if ! command -v cfssl &> /dev/null; then
    echo "Installing cfssl..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install cfssl
    else
        echo "Please install cfssl manually for your OS."
        exit 1
    fi
fi

if ! command -v cfssljson &> /dev/null; then
    echo "Installing cfssljson..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install cfssljson
    else
        echo "Please install cfssljson manually for your OS."
        exit 1
    fi
fi

mkdir -p build
pushd build

# Generate CSR and private key
cat > csr.json <<EOF
{
  "hosts": [],
  "CN": "teleport",
  "names": [{
        "O": "system:masters"
    }],
  "key": {
    "algo": "ecdsa",
    "size": 256
  }
}
EOF

cfssl genkey csr.json | cfssljson -bare server

# Self-sign the certificate using cfssl
cfssl selfsign teleport csr.json | cfssljson -bare server

# Extract the CA certificate from the Kubernetes cluster
kubectl -n kube-system get secret $(kubectl -n kube-system get sa default -o jsonpath='{.secrets[0].name}') -o jsonpath='{.data.ca\.crt}' | base64 ${BASE64_DECODE_FLAG} > ca.crt

# Extract cluster IP from the current context
CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name == \"${CURRENT_CONTEXT}\"})].context.cluster}")
CURRENT_CLUSTER_ADDR=$(kubectl config view -o jsonpath="{.clusters[?(@.name == \"${CURRENT_CLUSTER}\"})].cluster.server}")

cat > kubeconfig <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: $(cat ca.crt | base64 ${BASE64_WRAP_FLAG})
    server: ${CURRENT_CLUSTER_ADDR}
  name: k8s
contexts:
- context:
    cluster: k8s
    user: teleport
  name: k8s
current-context: k8s
kind: Config
preferences: {}
users:
- name: teleport
  user:
    client-certificate-data: $(cat server.pem | base64 ${BASE64_WRAP_FLAG})
    client-key-data: $(cat server-key.pem | base64 ${BASE64_WRAP_FLAG})
EOF

popd

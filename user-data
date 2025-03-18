#!/bin/bash
set -ex

# Update and install required dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl software-properties-common git

# Install Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install -y docker-ce
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

# Install Kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
mv ./kind /usr/local/bin/

# Clone the repository
cd /home/ubuntu
git clone https://github.com/tradevisapp/app.git
cd app

# Create the kind cluster using config from the repo
if [ -f kind-config.yaml ]; then
  kind create cluster --config kind-config.yaml
else
  # Create a default cluster if no config file exists
  kind create cluster --name tradevis-cluster
fi

# Wait for cluster to be ready
kubectl wait --for=condition=ready node --all --timeout=300s

# Apply Kubernetes manifests directly from the repository
if [ -d kubernetes ]; then
  kubectl apply -f kubernetes/
else
  echo "No kubernetes directory found in the repository. Nothing to apply."
fi

# Install ingress controller if needed
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for ingress controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

# Set proper permissions for the ubuntu user
chown -R ubuntu:ubuntu /home/ubuntu/app

echo "TradeVis App deployment complete!"

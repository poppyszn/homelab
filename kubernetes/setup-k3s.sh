#!/bin/bash
set -e  # Exit on any error

echo "=== K3s Production Setup Script ==="
echo "This will set up K3s with Calico, MetalLB, NGINX Ingress, NFS storage, cert-manager, and Prometheus"
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Function to wait for pods with retry on timeout
wait_for_pods() {
    local namespace=$1
    local selector=$2
    local timeout=${3:-180}
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        print_info "Waiting for pods in $namespace with selector $selector (attempt $((retry_count + 1))/$max_retries)..."
        
        if kubectl wait --namespace "$namespace" \
            --for=condition=ready pod \
            --selector="$selector" \
            --timeout="${timeout}s" 2>&1; then
            return 0
        else
            local wait_output=$(kubectl wait --namespace "$namespace" --for=condition=ready pod --selector="$selector" --timeout="${timeout}s" 2>&1 || true)
            
            if echo "$wait_output" | grep -q "timed out"; then
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    print_warning "Timeout detected, retrying..."
                    sleep 10
                else
                    print_warning "Pods may still be starting after $max_retries attempts"
                    return 1
                fi
            else
                # Some other error, return failure
                return 1
            fi
        fi
    done
}

# Check if running as root for k3s install
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root or with sudo"
    exit 1
fi

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
print_info "Detected server IP: $SERVER_IP"

# Calculate MetalLB IP range (SERVER_IP + 101 to 120)
IFS='.' read -r -a ip_parts <<< "$SERVER_IP"
METALLB_START="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$((${ip_parts[3]} + 101))"
METALLB_END="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$((${ip_parts[3]} + 120))"

print_info "MetalLB IP range will be: $METALLB_START-$METALLB_END"
echo ""

# Check if etcd is running
if ! docker ps | grep -q etcd; then
    print_error "etcd container is not running!"
    print_info "Please start etcd first with: docker start etcd"
    exit 1
fi

# Check etcd health
print_info "Checking etcd health..."
if ! docker exec etcd etcdctl endpoint health &>/dev/null; then
    print_error "etcd is not healthy!"
    print_warning "Attempting to fix etcd..."
    
    # Stop K3s if running
    systemctl stop k3s 2>/dev/null || true
    
    # Stop and remove etcd
    docker stop etcd 2>/dev/null || true
    
    # Clean etcd data
    print_info "Cleaning etcd data..."
    rm -rf /srv/etcd/data
    mkdir -p /srv/etcd/data
    chown -R 1001:1001 /srv/etcd/data
    chmod -R 700 /srv/etcd/data
    
    # Start fresh etcd
    print_info "Starting etcd..."
    docker start etcd 2>/dev/null || true
    
    sleep 10
    
    # Verify etcd is now healthy
    if ! docker exec etcd etcdctl endpoint health &>/dev/null; then
        print_error "Failed to start healthy etcd. Please check logs: docker logs etcd"
        exit 1
    fi
    print_success "etcd is now healthy"
fi

print_success "etcd is healthy"
echo ""

# Check if K3s is already installed
if systemctl is-active --quiet k3s && kubectl get nodes &>/dev/null; then
    print_warning "K3s is already installed and running"
    read -p "Do you want to reinstall K3s? This will WIPE ALL DATA (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Skipping K3s installation, will proceed with other components"
        SKIP_K3S=true
    else
        print_info "Uninstalling existing K3s..."
        /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
        SKIP_K3S=false
    fi
else
    SKIP_K3S=false
fi

if [ "$SKIP_K3S" = false ]; then
    read -p "Press Enter to continue with K3s installation or Ctrl+C to abort..."
    echo ""
fi

# Function to handle K3s installation errors
install_k3s() {
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        print_info "Installing K3s (attempt $((retry_count + 1))/$max_retries)..."
        
        if curl -sfL https://get.k3s.io | sh -s - \
          --disable traefik \
          --disable servicelb \
          --flannel-backend=none \
          --disable-network-policy \
          --datastore-endpoint="http://127.0.0.1:2379" \
          --write-kubeconfig-mode=644; then
            
            # Wait and check if K3s actually started
            sleep 10
            if systemctl is-active --quiet k3s; then
                print_success "K3s installed successfully"
                return 0
            fi
        fi
        
        # Check for the bootstrap error
        if journalctl -u k3s --no-pager -n 50 | grep -q "bootstrap data already found and encrypted with different token"; then
            print_warning "Detected etcd data mismatch. Cleaning up..."
            
            systemctl stop k3s 2>/dev/null || true
            docker stop etcd
            rm -rf /srv/etcd/data/*
            mkdir -p /srv/etcd/data
            chown -R 1001:1001 /srv/etcd/data
            chmod -R 700 /srv/etcd/data
            
            docker start etcd
            sleep 10
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            print_warning "Retrying K3s installation..."
            sleep 5
        fi
    done
    
    print_error "Failed to install K3s after $max_retries attempts"
    print_info "Check logs with: sudo journalctl -u k3s -n 100"
    exit 1
}

# Step 1: Install K3s
if [ "$SKIP_K3S" = false ]; then
    print_info "Step 1/9: Installing K3s..."
    install_k3s
else
    print_info "Step 1/9: Skipping K3s installation (already installed)"
fi

# Configure kubectl
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
if ! grep -q "KUBECONFIG=/etc/rancher/k3s/k3s.yaml" ~/.bashrc; then
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
fi

# Wait for K3s to be ready
print_info "Waiting for K3s API server to be ready..."
max_wait=60
waited=0
until kubectl get nodes &>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [ $waited -gt $max_wait ]; then
        print_error "K3s API server did not become ready in time"
        print_info "Check status with: sudo systemctl status k3s"
        exit 1
    fi
done
print_success "K3s is running"
echo ""

# Step 2: Install Calico
print_info "Step 2/9: Installing Calico CNI with BPF dataplane..."

# Apply CRDs (ignore AlreadyExists errors)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/operator-crds.yaml 2>&1 | grep -v "AlreadyExists" || true

# Apply operator
if kubectl get deployment tigera-operator -n tigera-operator &>/dev/null; then
    print_warning "Tigera operator already exists, skipping"
else
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/tigera-operator.yaml
fi

# Wait for operator
print_info "Waiting for Tigera operator..."
wait_for_pods "tigera-operator" "k8s-app=tigera-operator" 180

# Download and apply custom resources
if kubectl get installation default &>/dev/null; then
    print_warning "Calico installation already exists, skipping custom resources"
else
    curl -sO https://raw.githubusercontent.com/projectcalico/calico/v3.31.3/manifests/custom-resources-bpf.yaml
    sed -i 's|192.168.0.0/16|10.42.0.0/16|g' custom-resources-bpf.yaml
    kubectl create -f custom-resources-bpf.yaml
fi

# Wait for Calico
print_info "Waiting for Calico to be ready (this may take 2-3 minutes)..."
wait_for_pods "calico-system" "k8s-app=calico-node" 300
wait_for_pods "calico-system" "k8s-app=calico-kube-controllers" 180

# Wait for node to be Ready
print_info "Waiting for node to be Ready..."
max_wait=120
waited=0
until kubectl get nodes | grep -q " Ready"; do
    sleep 5
    waited=$((waited + 5))
    if [ $waited -gt $max_wait ]; then
        print_error "Node did not become Ready in time"
        kubectl get nodes
        exit 1
    fi
done
print_success "Calico installed and node is Ready"
echo ""

# Step 3: Install MetalLB
print_info "Step 3/9: Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml 2>&1 | grep -v "unchanged" || true

# Wait for MetalLB with retry
wait_for_pods "metallb-system" "app=metallb" 180

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - $METALLB_START-$METALLB_END
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
print_success "MetalLB installed with IP range $METALLB_START-$METALLB_END"
echo ""

# Step 4: Install NGINX Ingress
print_info "Step 4/9: Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.5/deploy/static/provider/cloud/deploy.yaml 2>&1 | grep -v "unchanged" || true

# Wait for NGINX ingress with retry
wait_for_pods "ingress-nginx" "app.kubernetes.io/component=controller" 180

print_success "NGINX Ingress installed"
echo ""

# Step 5: Install NFS CSI Driver
print_info "Step 5/9: Installing NFS CSI Driver..."
if kubectl get deployment csi-nfs-controller -n kube-system &>/dev/null; then
    print_warning "NFS CSI Driver already installed, skipping"
else
    curl -skSL https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.5.0/deploy/install-driver.sh | bash -s v4.5.0 --
fi

# Wait for NFS CSI driver pods (use different selectors)
print_info "Waiting for NFS CSI controller..."
wait_for_pods "kube-system" "app=csi-nfs-controller" 180

print_info "Waiting for NFS CSI node driver..."
# For DaemonSet pods, check if at least one is ready
max_wait=180
waited=0
until kubectl get pods -n kube-system -l app=csi-nfs-node --field-selector=status.phase=Running 2>/dev/null | grep -q "Running"; do
    sleep 5
    waited=$((waited + 5))
    if [ $waited -gt $max_wait ]; then
        print_warning "NFS CSI node driver may still be starting"
        break
    fi
done

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: $SERVER_IP
  share: /
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
EOF

kubectl patch storageclass nfs-csi -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
print_success "NFS CSI Driver installed with server $SERVER_IP"
echo ""

# Step 6: Install cert-manager
print_info "Step 6/9: Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.1/cert-manager.yaml 2>&1 | grep -v "unchanged" || true

# Wait for cert-manager with retry
wait_for_pods "cert-manager" "app.kubernetes.io/instance=cert-manager" 180

print_success "cert-manager installed"
echo ""

# Step 7: Install Helm
print_info "Step 7/9: Installing Helm..."
if ! command -v helm &> /dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    print_success "Helm installed"
else
    print_success "Helm already installed"
fi
echo ""

# Step 8: Install Prometheus + Grafana
print_info "Step 8/9: Installing Prometheus and Grafana (this may take 3-5 minutes)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Check if already installed
if helm list -n monitoring | grep -q prometheus; then
    print_warning "Prometheus stack already installed, skipping"
else
    # Install with timeout and error handling
    if ! helm install prometheus prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --set prometheus.prometheusSpec.retention=7d \
      --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
      --set grafana.persistence.enabled=true \
      --set grafana.persistence.size=5Gi \
      --wait --timeout=10m 2>/dev/null; then
        print_warning "Prometheus installation reported errors but may still be running"
        print_info "Waiting for pods to stabilize..."
        sleep 30
    fi
fi

# Get Grafana password with retry
max_retries=10
retry_count=0
GRAFANA_PASSWORD=""
while [ $retry_count -lt $max_retries ] && [ -z "$GRAFANA_PASSWORD" ]; do
    GRAFANA_PASSWORD=$(kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 --decode 2>/dev/null || echo "")
    if [ -z "$GRAFANA_PASSWORD" ]; then
        sleep 10
        retry_count=$((retry_count + 1))
    fi
done

if [ -z "$GRAFANA_PASSWORD" ]; then
    print_warning "Could not retrieve Grafana password yet. Check later with:"
    print_info "kubectl get secret -n monitoring prometheus-grafana -o jsonpath=\"{.data.admin-password}\" | base64 --decode"
    GRAFANA_PASSWORD="<retrieving...>"
fi

print_success "Prometheus and Grafana installed"
echo ""

# Step 9: Final verification
print_info "Step 9/9: Running final checks..."
sleep 10

echo ""
echo "=========================================="
echo "       Setup Complete!"
echo "=========================================="
echo ""
echo "Cluster Status:"
kubectl get nodes
echo ""
echo "Checking pod status across all namespaces..."
NOT_RUNNING=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2)
if [ -z "$NOT_RUNNING" ]; then
    print_success "All pods are running or completed!"
else
    print_warning "Some pods are not yet running:"
    echo "$NOT_RUNNING"
    print_info "This is normal if they're still starting. Check with: kubectl get pods -A"
fi
echo ""
echo "Storage Class:"
kubectl get storageclass
echo ""
echo "Ingress Controller:"
kubectl get svc -n ingress-nginx ingress-nginx-controller
echo ""
echo "=========================================="
echo "       Access Information"
echo "=========================================="
echo ""
echo "Grafana:"
echo "  Username: admin"
echo "  Password: $GRAFANA_PASSWORD"
echo "  Access:   kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  URL:      http://localhost:3000"
echo "  sudo k3s kubectl patch svc prometheus-grafana -n monitoring -p '{"spec": {"type": "LoadBalancer"}}'"
echo ""
echo "Prometheus:"
echo "  Access:   kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090"
echo "  URL:      http://localhost:9090"
echo ""
echo "=========================================="
echo "       Configuration"
echo "=========================================="
echo "  MetalLB IP Range:  $METALLB_START-$METALLB_END"
echo "  NFS Server:        $SERVER_IP"
echo "  StorageClass:      nfs-csi (default)"
echo ""
print_success "Your production-grade K3s cluster is ready!"
echo ""
echo "Next steps:"
echo "  1. Deploy a test application"
echo "  2. Set up GitOps with ArgoCD"
echo "  3. Configure CI/CD from GitHub"
echo ""
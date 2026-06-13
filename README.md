# Homelab K3s Infrastructure

A single-node K3s cluster on Ubuntu 24.04 with a production-grade toolchain.

## Stack

| Component | Version | Role |
|---|---|---|
| K3s | v1.33 (stable) | Kubernetes runtime |
| MetalLB | v0.16.1 | Bare metal LoadBalancer IPs |
| Traefik v3 | Bundled with K3s | Ingress controller |
| cert-manager | Latest (Jetstack) | TLS automation |
| Let's Encrypt | HTTP-01 | Certificate authority |
| Harbor | Latest (goharbor) | Private container registry |
| ArgoCD | Latest (argo-helm) | GitOps CD |
| cloudflared | Latest | Cloudflare Tunnel (zero open ports) |

---

## Directory Structure

```
homelab/
├── metallb/
│   ├── ip-address-pool.yaml       # MetalLB IP pool + L2Advertisement
│   └── INSTALL.md
├── cert-manager/
│   ├── cluster-issuer.yaml        # Let's Encrypt HTTP-01 ClusterIssuer
│   └── INSTALL.md
├── harbor/
│   ├── values.yaml                # Harbor Helm values (gitignored — copy from template)
│   ├── values.yaml.template       # Safe-to-commit template with placeholders
│   └── INSTALL.md
├── argocd/
│   ├── values.yaml                # ArgoCD Helm values
│   ├── ingress.yaml               # ArgoCD Ingress (gitignored — copy from template)
│   ├── ingress.yaml.template      # Safe-to-commit template with placeholders
│   └── INSTALL.md
├── cloudflared/
│   ├── namespace.yaml             # cloudflared namespace
│   ├── secret.yaml                # Token secret placeholder (do not commit real values)
│   ├── deployment.yaml            # cloudflared Deployment (2 replicas)
│   └── INSTALL.md
└── k3s/
    ├── registries.yaml            # K3s registry config (gitignored — copy from template)
    └── registries.yaml.template   # Safe-to-commit template with placeholders
```

---

## Initial Cluster Setup

### 1. System prep

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git open-iscsi nfs-common
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
sudo modprobe overlay && sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 2. Install K3s (ServiceLB disabled, Traefik enabled)

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - \
  --disable servicelb \
  --write-kubeconfig-mode 644

mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
chmod 600 ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

### 3. Install Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## Applying Manifests

### MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb && helm repo update

helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait

kubectl apply -f metallb/ip-address-pool.yaml
```

### cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait

# Edit your email in the file first
kubectl apply -f cert-manager/cluster-issuer.yaml
```

### Harbor

```bash
helm repo add harbor https://helm.goharbor.io && helm repo update

# Edit harbor/values.yaml with your domain and password first
helm install harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --values harbor/values.yaml \
  --wait --timeout 10m
```

### ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values argocd/values.yaml \
  --wait

kubectl apply -f argocd/ingress.yaml

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

### cloudflared

```bash
kubectl apply -f cloudflared/namespace.yaml

# Create token secret manually — never commit the real token
kubectl create secret generic cloudflared-token \
  --namespace cloudflared \
  --from-literal=token=YOUR_TOKEN_HERE

kubectl apply -f cloudflared/deployment.yaml
```

### K3s Registry Config (Harbor)

```bash
# Copy to host — this is not a kubectl apply
sudo cp k3s/registries.yaml /etc/rancher/k3s/registries.yaml
sudo systemctl restart k3s
```

---

## Cloudflare Tunnel — Service Routing

In Cloudflare Zero Trust → Tunnels → Public Hostnames, route through Traefik (not directly to each service) so ingress rules and TLS apply correctly:

| Public Hostname | Protocol | Internal URL | HTTP Host Header |
|---|---|---|---|
| `harbor.dev-pops.site` | HTTP | `traefik.kube-system.svc.cluster.local:80` | `harbor.dev-pops.site` |
| `argocd.dev-pops.site` | HTTP | `traefik.kube-system.svc.cluster.local:80` | `argocd.dev-pops.site` |

---

## Security Notes

- **Never commit real secrets.** Use the `cloudflared/secret.yaml` as a reference only.
- Use a **Harbor robot account** in `k3s/registries.yaml` instead of admin credentials.
- Change the ArgoCD admin password after first login.
- Consider [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) or [External Secrets Operator](https://external-secrets.io) for secret management in Git.

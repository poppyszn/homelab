# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure-as-code for a single-node K3s homelab cluster (Ubuntu 24.04). Everything here is Kubernetes manifests and Helm values — no application code, no build system, no test runner.

## Applying changes

This is a kubectl/helm repo. "Deploying" means running commands against a live cluster, not a local build step. Each component has its own `INSTALL.md` with the exact commands. The general pattern:

```bash
# Helm components
helm upgrade <release> <repo/chart> --namespace <ns> --values <component>/values.yaml

# Manifest-only components (cloudflared)
kubectl apply -f <component>/

# Host-level config (k3s registry)
sudo cp k3s/registries.yaml /etc/rancher/k3s/registries.yaml && sudo systemctl restart k3s
```

## Gitignore / template pattern

These files are gitignored because they contain real domains, credentials, or sensitive cluster output:

| Gitignored (local use) | Safe template (committed) |
|---|---|
| `harbor/values.yaml` | `harbor/values.yaml.template` |
| `argocd/ingress.yaml` | `argocd/ingress.yaml.template` |
| `k3s/registries.yaml` | `k3s/registries.yaml.template` |
| `vault-init.json` | *(no template — save to password manager only)* |

When adding new files that reference real domains or credentials, follow this same pattern: commit a `.template` with `YOUR_DOMAIN` / `CHANGE_ME` placeholders, gitignore the real file.

## Traffic flow

Cloudflare Tunnel → Traefik (in-cluster) → Ingress rules → Services.  
All public hostnames must route to `traefik.kube-system.svc.cluster.local:80` with an HTTP Host Header set — **not** directly to individual service ClusterDNS names. This is because ArgoCD runs with `server.insecure: true` and relies on Traefik for TLS termination.

## Domain

Real domain is `dev-pops.site`. Templates use `YOUR_DOMAIN` as the placeholder.

## Stack install order

Dependencies exist between components — install in this order:
1. MetalLB (required before any LoadBalancer service gets an IP)
2. cert-manager (required before any cert-manager annotations are evaluated)
3. Harbor (optional, needed if pulling images from the private registry)
4. K3s registry config (after Harbor is up)
5. Vault + VSO (before any workload that needs synced secrets)
6. ArgoCD
7. cloudflared (after ArgoCD and Harbor are reachable internally)

## Vault operational notes

- After every `vault-0` pod restart (reboot, eviction), Vault is **sealed** and needs manual unseal before VSO can sync secrets. Run: `kubectl exec -n vault vault-0 -- vault operator unseal <key>`
- `vault-init.json` (unseal key + root token) must never be committed — it is gitignored. Store it in a password manager.
- Vault UI is intentionally not exposed through Cloudflare Tunnel. Use `kubectl port-forward -n vault svc/vault 8200:8200` for local access.
- All homelab secrets live at the `homelab/` KV-v2 path. VSO syncs them via `VaultStaticSecret` resources in each component's namespace.

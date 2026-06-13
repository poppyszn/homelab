# ArgoCD

## Add Helm Repo

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

## Install

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values values.yaml \
  --wait
```

## Upgrade (e.g. after enabling insecure mode for ingress)

```bash
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --values values.yaml \
  --wait

kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
```

## Apply Ingress

```bash
kubectl apply -f ingress.yaml

# Verify cert issues
kubectl get certificate -n argocd --watch
```

## Get Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

## Get External IP (LoadBalancer, LAN access)

```bash
kubectl get svc argocd-server -n argocd
```

Access the UI at:
- `https://argocd.dev-pops.site` (via Cloudflare Tunnel)
- `https://<EXTERNAL-IP>` (LAN, MetalLB IP)

Username: `admin`. Change the password immediately after first login.

## Cloudflare Tunnel — Public Hostname

In Zero Trust → Tunnels → your tunnel → Public Hostnames:

| Field | Value |
|---|---|
| Subdomain | `argocd` |
| Domain | `dev-pops.site` |
| Protocol | `HTTP` |
| URL | `traefik.kube-system.svc.cluster.local:80` |
| HTTP Host Header | `argocd.dev-pops.site` |

## Verify

```bash
kubectl get pods -n argocd
kubectl get ingress -n argocd
```

## Uninstall

```bash
helm uninstall argocd --namespace argocd
kubectl delete namespace argocd
```
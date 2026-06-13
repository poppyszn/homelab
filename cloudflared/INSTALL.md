# cloudflared

Not a Helm chart — deployed via kubectl manifests.

## Install

```bash
kubectl apply -f namespace.yaml
```

Create the token secret manually. Never commit the real token to Git:

```bash
kubectl create secret generic cloudflared-token \
  --namespace cloudflared \
  --from-literal=token=YOUR_TOKEN_HERE
```

```bash
kubectl apply -f deployment.yaml
```

## Verify

```bash
kubectl get pods -n cloudflared
kubectl logs -n cloudflared -l app=cloudflared --tail=20
```

## Cloudflare Zero Trust — Public Hostname Routing

In the Cloudflare dashboard under **Zero Trust → Networks → Tunnels → your tunnel → Public Hostnames**,
route through Traefik so ingress rules and TLS apply correctly:

| Public Hostname | Protocol | Internal URL | HTTP Host Header |
|---|---|---|---|
| `harbor.dev-pops.site` | HTTP | `traefik.kube-system.svc.cluster.local:80` | `harbor.dev-pops.site` |
| `argocd.dev-pops.site` | HTTP | `traefik.kube-system.svc.cluster.local:80` | `argocd.dev-pops.site` |

## Uninstall

```bash
kubectl delete -f deployment.yaml
kubectl delete secret cloudflared-token -n cloudflared
kubectl delete -f namespace.yaml
```

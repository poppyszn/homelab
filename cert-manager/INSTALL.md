# cert-manager

## Add Helm Repo

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
```

## Install

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
```

## Apply ClusterIssuer

```bash
kubectl apply -f cluster-issuer.yaml
```

## Verify

```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer letsencrypt-prod
```

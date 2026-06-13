# Harbor

## Add Helm Repo

```bash
helm repo add harbor https://helm.goharbor.io
helm repo update
```

## Install

> Edit `values.yaml` with your domain and admin password before running.

```bash
helm install harbor harbor/harbor \
  --namespace harbor \
  --create-namespace \
  --values values.yaml \
  --wait --timeout 10m
```

## Verify

```bash
kubectl get pods -n harbor
kubectl get ingress -n harbor
kubectl get certificate -n harbor
```

## Uninstall

```bash
helm uninstall harbor --namespace harbor
kubectl delete namespace harbor
```

> Note: PersistentVolumeClaims are not deleted automatically. Run the following to clean them up:
>
> ```bash
> kubectl delete pvc --all -n harbor
> ```

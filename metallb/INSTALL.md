# MetalLB

## Add Helm Repo

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
```

## Install

```bash
helm install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait
```

## Apply IP Pool

```bash
kubectl apply -f ip-address-pool.yaml
```

## Verify

```bash
kubectl get pods -n metallb-system
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

# Vault + Vault Secrets Operator

Standalone Vault with integrated Raft storage + VSO for syncing secrets into K8s native Secrets.

## Add Helm Repo

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

## Install Vault

```bash
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --values values.yaml \
  --wait

kubectl get pods -n vault
```

`vault-0` will show `0/1` — expected. It's sealed and uninitialized.

## Initialize and Unseal

```bash
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 vault operator init \
  -key-shares=1 -key-threshold=1 -format=json" \
  > vault-init.json
```

**Save `vault-init.json` in your password manager and delete the local file — it contains your unseal key and root token. Never commit it.**

```bash
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' vault-init.json)

kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $UNSEAL_KEY"

kubectl get pods -n vault   # should now show 1/1 Running
```

> **Every time `vault-0` restarts** (node reboot, pod eviction), Vault is sealed again and needs the unseal command re-run. This is an acceptable homelab tradeoff — auto-unseal requires a cloud KMS.

## Enable KV Engine + Kubernetes Auth

```bash
ROOT_TOKEN=$(jq -r '.root_token' vault-init.json)

kubectl exec -n vault vault-0 -- sh -c "
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$ROOT_TOKEN

vault secrets enable -path=homelab kv-v2
vault auth enable kubernetes

vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443
"
```

## Create VSO Policy and Role

```bash
kubectl exec -n vault vault-0 -- sh -c "
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$ROOT_TOKEN

vault policy write vso-reader - <<EOF
path \"homelab/data/*\" {
  capabilities = [\"read\"]
}
EOF

vault write auth/kubernetes/role/vso-reader \
  bound_service_account_names=vault-secrets-operator-controller-manager \
  bound_service_account_namespaces=vault-secrets-operator-system \
  policies=vso-reader \
  ttl=24h
"
```

## Install Vault Secrets Operator

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator-system \
  --create-namespace \
  --version 1.4.0 \
  --wait

kubectl get pods -n vault-secrets-operator-system
```

## Apply VaultConnection + VaultAuth

```bash
kubectl apply -f vso-connection.yaml
```

This is cluster-wide — `allowedNamespaces: ["*"]` means any namespace can reference this auth in a `VaultStaticSecret`.

## Migrate cloudflared Token into Vault

Write the secret into Vault (one-time, replaces `kubectl create secret`):

```bash
kubectl exec -n vault vault-0 -- sh -c "
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$ROOT_TOKEN

vault kv put homelab/cloudflared token='YOUR_TUNNEL_TOKEN_HERE'
"
```

Apply the VSO sync manifest:

```bash
kubectl apply -f ../cloudflared/vault-secret.yaml

# Verify the K8s secret was synced from Vault
kubectl get secret cloudflared-token -n cloudflared -o jsonpath='{.data.token}' | base64 -d
```

From here, rotating the token means `vault kv put homelab/cloudflared token='...'` — VSO re-syncs within `refreshAfter: 1h`.

## Other Secrets to Migrate

| Secret | Vault path | Notes |
|---|---|---|
| Cloudflare tunnel token | `homelab/cloudflared` | Done above |
| Harbor admin password | `homelab/harbor` | Or use a robot account token |
| K3s registry credentials | `homelab/k3s-registry` | Harbor robot account |

Leave `harbor-tls` and `argocd-tls` alone — those are managed by cert-manager.

## Vault UI (LAN Only)

**Do not expose Vault through Cloudflare Tunnel** — it holds the keys to everything else.

For local access:

```bash
kubectl port-forward -n vault svc/vault 8200:8200
```

Then browse `http://localhost:8200`. Log in with the root token for initial setup, then create a less-privileged admin token and stop using root day-to-day.

## Verify

```bash
kubectl get pods -n vault
kubectl get pods -n vault-secrets-operator-system
kubectl get vaultconnection -n vault-secrets-operator-system
kubectl get vaultauth -n vault-secrets-operator-system
```

## Uninstall

```bash
helm uninstall vault-secrets-operator --namespace vault-secrets-operator-system
helm uninstall vault --namespace vault
kubectl delete namespace vault vault-secrets-operator-system
# PVCs are not deleted automatically
kubectl delete pvc --all -n vault
```

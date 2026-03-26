# Phase 2b — Gestion des secrets HyperShift (Vault → ESO → K8s)

## Contexte

Avant de créer le HostedCluster Azure (Phase 3), tous les secrets sensibles
doivent être gérés via la chaîne Vault → ESO → Kubernetes Secret.
Cela garantit qu'aucun secret ne transite en clair dans le repo GitHub.

---

## Architecture secrets HyperShift

```
┌─────────────────────────────────────────────────────────────────┐
│                    Vault KV v2 (namespace vault)                │
│                                                                 │
│  secret/hypershift/tailscale                                    │
│    └── auth-key = <ephemeral key>                               │
│                                                                 │
│  secret/hypershift/azure          ← Phase 3                     │
│    ├── client-id                                                │
│    ├── client-secret                                            │
│    ├── subscription-id                                          │
│    └── tenant-id                                                │
└─────────────────────────────────────────────────────────────────┘
                          │
                          │ Kubernetes auth (JWT + CA cert)
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│           ClusterSecretStore: vault-cluster-backend             │
│           (namespace: external-secrets)                         │
│                                                                 │
│  role: eso-hypershift                                           │
│  SA:   cluster-external-secrets / external-secrets             │
│  path: secret (KV v2)                                           │
└─────────────────────────────────────────────────────────────────┘
                          │
                          │ sync toutes les heures
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│              namespace: clusters                                │
│                                                                 │
│  ExternalSecret: tailscale-authkey                              │
│    └── K8s Secret: tailscale-authkey                            │
│          └── data.auth-key = <ephemeral key>                    │
│                                                                 │
│  ExternalSecret: azure-credentials    ← Phase 3                 │
│    └── K8s Secret: azure-credentials                            │
└─────────────────────────────────────────────────────────────────┘
                          │
                          │ référencé dans
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│         HostedCluster CR + NodePool CR (Phase 3)               │
│                                                                 │
│  spec.platform.azure.credentials → secret/azure-credentials    │
│  NodePool userdata               → secret/tailscale-authkey    │
└─────────────────────────────────────────────────────────────────┘
```

---

## ClusterSecretStore — vault-cluster-backend

### Pourquoi un ClusterSecretStore ?

Un `SecretStore` est namespaced — il ne peut servir que le namespace où il est
déployé. Le namespace `clusters` est créé dynamiquement par HyperShift et doit
pouvoir consommer des secrets Vault sans dépendre d'un SecretStore local.

Un `ClusterSecretStore` est cluster-scoped : il permet à n'importe quel
namespace d'y référer, ce qui est indispensable pour HyperShift.

### Manifest

```yaml
# manifests/eso/03-cluster-secret-store.yaml
# Repo : Openshift-OKD-SNO-Airgap-workstation (géré par ArgoCD app eso-hypershift)
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-cluster-backend
spec:
  provider:
    vault:
      server: http://vault.vault.svc.cluster.local:8200
      path: secret
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso-hypershift
          serviceAccountRef:
            name: cluster-external-secrets
            namespace: external-secrets
```

### Vault role eso-hypershift

```hcl
# Policies accordées
path "secret/data/hypershift/*" { capabilities = ["read"] }
path "secret/metadata/hypershift/*" { capabilities = ["read", "list"] }
path "secret/data/keycloak/*"   { capabilities = ["read"] }
path "secret/data/grafana/*"    { capabilities = ["read"] }

# Bound SA
bound_service_account_names      = cluster-external-secrets
bound_service_account_namespaces = external-secrets
ttl = 1h
```

---

## Secret Tailscale — flux complet

### Pourquoi stocker la clé Tailscale dans Vault ?

La clé Tailscale (`auth-key`) permet à un worker Azure de rejoindre le réseau
Tailscale du homelab. Si elle est compromise, un attaquant peut introduire un
nœud arbitraire dans le réseau. Elle ne doit jamais apparaître en clair dans
le repo GitHub ni dans les manifests YAML.

### Flux

```
1. Clé créée dans Tailscale Admin Console (ephemeral, reusable)
   → stockée dans Vault via UI : secret/hypershift/tailscale.auth-key

2. ESO ClusterSecretStore interroge Vault via Kubernetes auth
   → crée/met à jour K8s Secret tailscale-authkey dans namespace clusters
   → refresh toutes les heures

3. NodePool CR référence le secret dans le userdata cloud-init
   → au démarrage, chaque worker Azure exécute :
      tailscale up --authkey=$(cat /etc/tailscale/auth-key) --hostname=worker-<id>

4. Worker visible dans tailscale status depuis sno-master
   → kubelet peut joindre le HCP via 100.x.x.x
```

### ExternalSecret

```yaml
# manifests/eso/externalsecret-tailscale.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: tailscale-authkey
  namespace: clusters
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-cluster-backend
    kind: ClusterSecretStore
  target:
    name: tailscale-authkey
    creationPolicy: Owner
  data:
    - secretKey: auth-key
      remoteRef:
        key: hypershift/tailscale
        property: auth-key
```

### Vérification

```bash
oc get clustersecretstore vault-cluster-backend
# STATUS: Valid / READY: True

oc get externalsecret tailscale-authkey -n clusters
# STATUS: SecretSynced / READY: True

oc get secret tailscale-authkey -n clusters \
  -o jsonpath='{.data.auth-key}' | base64 -d
# → affiche la clé (ne pas committer ce output)
```

---

## Sécurité — points clés

| Risque | Mitigation |
|--------|-----------|
| Clé Tailscale en clair dans le repo | Stockée dans Vault, jamais dans Git |
| Credentials Azure SP exposés | Vault KV + ESO, pas de Secret YAML dans Git |
| Token Vault root utilisé en prod | À remplacer par un token AppRole dédié (post-Phase 3) |
| Clé Tailscale non révocable | Utiliser une clé ephemeral → révocation auto à la suppression du node |

---

## Prochaine étape — Phase 3

```
1. az ad sp create-for-rbac --name hypershift-azure-sp
2. Stocker client-id/secret dans Vault : secret/hypershift/azure
3. Créer ExternalSecret azure-credentials dans namespace clusters
4. Créer HostedCluster CR + NodePool CR
5. Valider workers Ready via tailscale status
```

# OKD HyperShift Security Platform — Demo Walkthrough

> **Portfolio project by Stéphane Seloi** — Freelance Cloud Native Security Architect  
> This document walks through the full deployment of a HyperShift Hosted Control Plane on OKD SNO with Azure Spot workers, secured end-to-end with Zero Trust networking, GitOps, and supply chain controls.

---

## Architecture

![Architecture Overview](screenshots/architecture-overview.png)

**Key architectural insight**: HyperShift decouples the Control Plane from the Data Plane. The entire Hosted Cluster Control Plane (kube-apiserver, etcd, controllers) runs as pods inside OKD SNO, while Azure Spot VMs handle only the data plane — reducing infrastructure costs by ~60% vs a traditional cluster.

The only external attack surface is the link between the Hosted Control Plane pods and the Azure workers, secured via **Tailscale mTLS (WireGuard)**.

---

## Lab Environment

| Component | Details |
|---|---|
| Management Cluster | OKD SNO 4.15 — `sno-master` (<sno-master-ip>) |
| Hypervisor | VMware Workstation Pro — GEEKOM A6 (Ryzen 6900HX, 32GB DDR5) |
| Harbor VM | harbor.okd.lab — <harbor-ip> |
| Azure Region | westeurope |
| Worker type | Standard_D4s_v3 Spot |
| Autoscaling | 1 → 5 nodes |
| Zero Trust | Tailscale WireGuard mTLS |

---

## Phase 1 — HyperShift Operator Installation

### 1.1 Prerequisites — OKD SNO cluster healthy

```bash
$ oc get nodes
NAME         STATUS   ROLES                         AGE   VERSION
sno-master   Ready    control-plane,master,worker   15d   v1.28.2
```

```bash
$ oc get applications -n openshift-operators
NAME             SYNC STATUS   HEALTH STATUS
eso              Synced        Healthy
grafana          Synced        Healthy
keycloak         Synced        Healthy
vault            Synced        Healthy
loki             Synced        Healthy
kyverno          Synced        Healthy
root-app         Synced        Healthy
```

![ArgoCD Applications](screenshots/phase1/01-argocd-apps-healthy.png)

### 1.2 Azure Cost Management — Budget alert configured

Budget `ai-platform-budget` at $50/month active on the Azure subscription. This ensures no unexpected costs from Azure Spot workers.

### 1.3 HyperShift CLI installation

The HyperShift binary is extracted from the official container image:

```bash
podman cp \
  $(podman create --name hypershift --rm --pull always \
    quay.io/hypershift/hypershift-operator:latest \
  ):/usr/bin/hypershift /tmp/hypershift

sudo install -m 0755 /tmp/hypershift /usr/local/bin/hypershift
```

### 1.4 Compatibility patch — OKD 4.15 / Kubernetes 1.28

HyperShift `latest` uses CEL function `isIP()` introduced in Kubernetes 1.29. OKD 4.15 runs Kubernetes 1.28. The two affected CRDs are patched before apply:

```python
# Remove x-kubernetes-validations blocks containing isIP()
def remove_isip_validations(obj):
    if isinstance(obj, dict):
        if 'x-kubernetes-validations' in obj:
            obj['x-kubernetes-validations'] = [
                rule for rule in obj['x-kubernetes-validations']
                if isinstance(rule, dict) and 'isIP' not in rule.get('rule', '')
            ]
```

Applied with `--server-side` to bypass the 262144 bytes annotation limit on large CRDs:

```bash
oc apply --server-side --force-conflicts -f hypershift-install-patched.yaml
```

### 1.5 HyperShift Operator running

```bash
$ oc get pods -n hypershift
NAME                        READY   STATUS    RESTARTS   AGE
operator-86c64f5d44-f7lgc   1/1     Running   1          31m
operator-86c64f5d44-mpksk   1/1     Running   0          31m
```

![HyperShift Operator Running](screenshots/phase1/02-hypershift-operator-running.png)

### 1.6 HyperShift CRDs registered

```bash
$ oc get crd | grep hypershift
hostedclusters.hypershift.openshift.io
hostedcontrolplanes.hypershift.openshift.io
nodepools.hypershift.openshift.io
...
```

![HyperShift CRDs](screenshots/phase1/04-hypershift-crds.png)

---

## Phase 2 — Tailscale Zero Trust Network

### 2.1 Why Tailscale

The Hosted Control Plane pods on OKD SNO need to communicate with Azure worker nodes over the internet. Rather than exposing a public endpoint, Tailscale provides:

- **WireGuard encryption** — all traffic between SNO and Azure workers is encrypted
- **Zero Trust** — workers authenticate with an ephemeral auth key before joining the network
- **No public IP on SNO** — the management cluster is never directly exposed

```
Azure Worker (100.x.x.x) ──── WireGuard ──── sno-master (<sno-tailscale-ip>)
                                mTLS           Subnet Router <sno-subnet>/24
```

### 2.2 Tailscale Auth Keys

> ⚠️ Screenshot omitted — contains sensitive auth key material.

Two auth keys configured:
- **Reusable + Pre-approved** → for `sno-master` (permanent node)
- **Reusable + Ephemeral** → for Azure workers (automatically removed when evicted)

### 2.3 Tailscale DaemonSet deployment

Tailscale is deployed as a privileged DaemonSet on OKD SNO. Key design decisions:

| Setting | Value | Reason |
|---|---|---|
| `hostNetwork: true` | yes | Access host network interfaces |
| `dnsPolicy` | `ClusterFirstWithHostNet` | Resolve `kubernetes.default.svc` with CoreDNS |
| `serviceAccountName` | `tailscale` | Dedicated SA with RBAC to read/write Secrets |
| `SCC` | `privileged` | OpenShift requires explicit SCC grant for privileged pods |
| `TS_ROUTES` | `<sno-subnet>/24` | Advertise OKD SNO subnet to Tailscale network |

```bash
$ oc get pods -n tailscale
NAME              READY   STATUS    RESTARTS   AGE
tailscale-ktjhs   1/1     Running   0          2d
```

![Tailscale Pod Running](screenshots/phase2/03-tailscale-pod-running.png)

### 2.4 sno-master connected to Tailscale network

> ⚠️ Screenshot omitted — contains account email and Tailscale IP.

`sno-master` is connected with IP **<sno-tailscale-ip>**, advertising subnet `<sno-subnet>/24` (approved). DERP relay: Frankfurt (fra) — optimal for westeurope Azure region.

```bash
$ oc exec -n tailscale daemonset/tailscale -- tailscale status
<sno-tailscale-ip>   sno-master   <tailscale-account>@   linux   -
```

> ⚠️ Screenshot omitted — contains account email and Tailscale IP.

---

## Phase 2b — Secrets Management (Vault → ESO → Kubernetes)

> All sensitive credentials are managed through a secure chain: HashiCorp Vault → External Secrets Operator → Kubernetes Secrets. No secrets are ever stored in Git.

### 2b.1 Vault Kubernetes Auth Backend

The Vault Kubernetes auth backend was configured to allow ESO to authenticate using its ServiceAccount JWT token, validated against the OKD SNO API server CA certificate.

```bash
# Enable Kubernetes auth
vault auth enable kubernetes

# Configure with OKD SNO CA and token reviewer
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
```

**Root cause fixed**: The Vault Kubernetes auth backend was not enabled — ESO SecretStores were returning `403 permission denied` on all namespaces.

### 2b.2 Vault Policies and Roles

Three policies and roles created for least-privilege access:

| Role | ServiceAccount | Namespace | Policies |
|------|---------------|-----------|----------|
| `keycloak` | `cluster-external-secrets` | `external-secrets` | `keycloak-policy` |
| `grafana` | `cluster-external-secrets` | `external-secrets` | `grafana-policy` |
| `eso-hypershift` | `cluster-external-secrets` | `external-secrets` | `keycloak-policy`, `grafana-policy`, `hypershift-policy` |

### 2b.3 ESO SecretStores — all healthy

```bash
$ oc get secretstore -A
NAMESPACE          NAME            STATUS   CAPABILITIES   READY
grafana-operator   vault-backend   Valid    ReadWrite      True
keycloak           vault-backend   Valid    ReadWrite      True

$ oc get externalsecret -A
NAMESPACE          NAME                       STATUS         READY
grafana-operator   grafana-prometheus-token   SecretSynced   True
keycloak           keycloak-secrets           SecretSynced   True
```

![ESO SecretStores Ready](screenshots/phase2b/01-eso-secretstores-ready.png)

### 2b.4 ClusterSecretStore — cross-namespace for HyperShift

A `ClusterSecretStore` (cluster-scoped) was created to allow the dynamically-created `clusters` namespace to consume secrets from Vault without a per-namespace SecretStore.

```bash
$ oc get clustersecretstore
NAME                    AGE   STATUS   CAPABILITIES   READY
vault-cluster-backend   1h    Valid    ReadWrite      True
```

Managed via ArgoCD (`eso-hypershift` application) from the Airgap repo — GitOps compliant.

### 2b.5 Tailscale auth key secured in Vault

```
Vault KV: secret/hypershift/tailscale.auth-key
  → ESO ExternalSecret (namespace: clusters)
  → K8s Secret: tailscale-authkey
```

```bash
$ oc get externalsecret tailscale-authkey -n clusters
NAME                STORE                   REFRESH INTERVAL   STATUS         READY
tailscale-authkey   vault-cluster-backend   1h                 SecretSynced   True
```

![Tailscale Secret Synced](screenshots/phase2b/02-tailscale-secret-synced.png)

### 2b.6 Azure credentials secured in Vault

```
Vault KV: secret/hypershift/azure
  ├── client-id
  ├── client-secret
  ├── tenant-id
  └── subscription-id
  → ESO ExternalSecret (namespace: clusters)
  → K8s Secret: azure-credentials (4 keys)
```

```bash
$ oc get externalsecret azure-credentials -n clusters
NAME                STORE                   REFRESH INTERVAL   STATUS         READY
azure-credentials   vault-cluster-backend   1h                 SecretSynced   True
```

![Azure Credentials Synced](screenshots/phase2b/03-azure-credentials-synced.png)

### 2b.7 Secrets summary — namespace clusters ready

```bash
$ oc get secrets -n clusters
NAME                TYPE                             DATA   AGE
tailscale-authkey   Opaque                           1      4h
azure-credentials   Opaque                           4      1h
pull-secret         kubernetes.io/dockerconfigjson   1      1h
ssh-key             Opaque                           1      1h
```

All secrets required by the HostedCluster CR are present. **No secret exists in Git.**

![Clusters Namespace Secrets](screenshots/phase2b/04-clusters-secrets-ready.png)

---

## Phase 3 — Azure HostedCluster Creation

### 3.1 Azure Service Principal

A dedicated Service Principal `hypershift-azure-sp` was created with `Contributor` role scoped to the subscription. Credentials are stored exclusively in Vault — never in Git or environment files.

```bash
az ad sp create-for-rbac \
  --name "hypershift-azure-sp" \
  --role Contributor \
  --scopes /subscriptions/<subscription-id> \
  --output json
```

![Azure SP Created](screenshots/phase3/01-azure-sp-created.png)

### 3.2 Azure Infrastructure — Terraform

Infrastructure is provisioned via Terraform (`infra/azure/`) for reproducibility and clean teardown. No Azure CLI imperative commands in the workflow.

```bash
cd infra/azure

# Credentials injected from Vault — never in files
export ARM_CLIENT_ID="$(vault kv get -field=client-id secret/hypershift/azure)"
export ARM_CLIENT_SECRET="$(vault kv get -field=client-secret secret/hypershift/azure)"
export ARM_TENANT_ID="$(vault kv get -field=tenant-id secret/hypershift/azure)"
export ARM_SUBSCRIPTION_ID="$(vault kv get -field=subscription-id secret/hypershift/azure)"

export TF_VAR_subscription_id="$ARM_SUBSCRIPTION_ID"
export TF_VAR_tenant_id="$ARM_TENANT_ID"

terraform init
terraform plan
terraform apply
```

Resources created:

| Resource | Name |
|----------|------|
| Resource Group | rg-hypershift-okd-azure-nodepools |
| Virtual Network | vnet-hypershift (10.0.0.0/16) |
| Subnet | subnet-workers (10.0.1.0/24) |
| NSG | nsg-hypershift-workers |

NSG rules — inbound:

| Priority | Rule | Protocol | Port | Source |
|----------|------|----------|------|--------|
| 100 | AllowTailscaleInbound | UDP | 41641 | * |
| 110 | AllowHTTPSInbound | TCP | 443 | 100.64.0.0/10 (Tailscale CGNAT) |
| 120 | AllowSSHDebug | TCP | 22 | 100.64.0.0/10 (Tailscale CGNAT) |

> **📸 Screenshot to add**: `phase3/02-terraform-apply.png` — `terraform apply` output

### 3.3 HostedCluster CR created

> **📸 Screenshot to add**: `phase3/03-hostedcluster-cr.png` — `oc get hostedcluster -n clusters`

### 3.4 Hosted Control Plane pods running on SNO

> **📸 Screenshot to add**: `phase3/04-hcp-pods-running.png` — `oc get pods -n clusters-okd-azure-nodepools`

### 3.5 Azure workers bootstrapping

> **📸 Screenshot to add**: `phase3/05-azure-vms-provisioning.png` — Azure portal VMs being created

### 3.6 Workers joining via Tailscale

> **📸 Screenshot to add**: `phase3/06-tailscale-workers-connected.png` — Tailscale dashboard with Azure workers

### 3.7 HostedCluster nodes Ready

> **📸 Screenshot to add**: `phase3/07-hosted-cluster-nodes-ready.png` — `oc get nodes` on hosted cluster

---

## Phase 4 — Supply Chain Security

> 🚧 **Planned**

### 4.1 Harbor registry — image scanning with Trivy

> **📸 Screenshot to add**: `phase4/01-harbor-trivy-scan.png`

### 4.2 Cosign image signing in CI pipeline

> **📸 Screenshot to add**: `phase4/02-cosign-signature-verified.png`

### 4.3 Kyverno policy — enforce signed images on HostedCluster

> **📸 Screenshot to add**: `phase4/03-kyverno-policy-enforced.png`

---

## Phase 5 — Observability & IAM

> 🚧 **Planned**

### 5.1 Grafana — Hosted Cluster metrics federated to SNO

> **📸 Screenshot to add**: `phase5/01-grafana-hosted-cluster-metrics.png`

### 5.2 Loki — Azure worker logs aggregated

> **📸 Screenshot to add**: `phase5/02-loki-worker-logs.png`

### 5.3 Keycloak OIDC — Hosted Cluster API authentication

> **📸 Screenshot to add**: `phase5/03-keycloak-oidc-hostedcluster.png`

### 5.4 Vault — Hosted Cluster secrets management

> **📸 Screenshot to add**: `phase5/04-vault-secrets-hostedcluster.png`

---

## Security Posture Summary

| Domain | Control | Status |
|---|---|---|
| Network | Tailscale WireGuard mTLS | ✅ Phase 2 |
| Network | Zero Trust — no public CP endpoint | ✅ Phase 2 |
| Secrets | HashiCorp Vault + ESO | ✅ Phase 2b |
| Secrets | No secrets in Git | ✅ Phase 2b |
| IAM | Keycloak OIDC SSO | ✅ Deployed |
| IAM | Vault Kubernetes auth — least privilege | ✅ Phase 2b |
| Supply Chain | Harbor + Trivy image scanning | 🔜 Phase 4 |
| Supply Chain | Cosign image signing | 🔜 Phase 4 |
| Policy | Kyverno admission control | ✅ Deployed |
| Observability | Prometheus + Grafana + Loki | ✅ Deployed |
| GitOps | ArgoCD — all deployments | ✅ Deployed |
| IaC | Terraform — Azure infra | ✅ Phase 3 |
| Cost | Azure budget alert $50/month | ✅ Phase 1 |

---

## Key Technical Challenges & Solutions

| Challenge | Solution |
|---|---|
| HyperShift CEL `isIP()` incompatible with k8s 1.28 | Python script to patch CRDs before apply |
| CRD too large for client-side apply (>262144 bytes) | `--server-side --force-conflicts` apply |
| Tailscale pod DNS resolution with `hostNetwork: true` | `dnsPolicy: ClusterFirstWithHostNet` |
| Tailscale pod rejected by OKD PodSecurity | Dedicated ServiceAccount + SCC `privileged` |
| MCE not available on OKD (Red Hat subscription required) | HyperShift standalone operator via CLI |
| Vault Kubernetes auth backend not enabled | `vault auth enable kubernetes` + CA cert config |
| ESO `403 permission denied` on all SecretStores | Role bound to `cluster-external-secrets` SA (ESO's actual SA) |
| HyperShift Azure requires full resource IDs | Terraform outputs provide exact `/subscriptions/.../` paths |
| Azure SP credentials exposed in chat history | Immediate credential rotation via `az ad sp credential reset` |

---

## Repository Structure

```
okd-hypershift-security-platform/
├── argocd/
│   └── applications/
│       └── eso-hypershift.yaml         # ClusterSecretStore ArgoCD app
├── infra/
│   └── azure/                          # Terraform — Azure network infra
│       ├── versions.tf
│       ├── variables.tf
│       ├── main.tf
│       ├── outputs.tf
│       └── README.md
├── manifests/
│   ├── eso/
│   │   ├── cluster-secret-store.yaml   # ClusterSecretStore (ref only)
│   │   ├── externalsecret-tailscale.yaml
│   │   └── externalsecret-azure.yaml
│   ├── hypershift/
│   │   ├── hypershift-install-patched.yaml
│   │   ├── hosted-cluster.yaml         # HostedCluster CR
│   │   └── nodepool.yaml               # NodePool CR (1x D4s_v3 Spot)
│   └── tailscale/
│       └── daemonset-sno.yaml
├── docs/
│   ├── phase2b-secrets-hypershift.md
│   └── demo/
│       ├── DEMO.md
│       └── screenshots/
├── SECURITY.md
└── README.md
```

---

## Author

**Stéphane Seloi** — Freelance Cloud Native Security Architect  
GitHub: [Z3ROX-lab](https://github.com/Z3ROX-lab)  
Certifications: CCSP · AWS Solutions Architect · ISO 27001 Lead Implementer · CompTIA Security+

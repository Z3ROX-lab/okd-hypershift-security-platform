# OKD HyperShift Security Platform

> **Portfolio project** — Hosted Control Planes on OKD SNO with Azure Spot workers, secured end-to-end with Zero Trust, GitOps, and supply chain controls.

---

## Architecture Overview

![Architecture Overview](docs/architecture/architecture-overview.svg)

```
┌─────────────────────────────────────────────────────────────────────┐
│                  OKD SNO — Management Cluster                       │
│                  sno-master · <sno-master-ip>                       │
│                                                                     │
│  ┌─────────────────────┐    ┌──────────────────────────────────┐   │
│  │   Stack existante   │    │        HyperShift Operator       │   │
│  │  ✓ Keycloak · Vault │    │      standalone (no MCE)         │   │
│  │  ✓ ArgoCD · ESO     │    └───────────────┬──────────────────┘   │
│  │  ✓ Grafana · Loki   │                    │                      │
│  │  ✓ Kyverno          │                    ▼                      │
│  │  ✓ Actions Runner   │    ┌──────────────────────────────────┐   │
│  └─────────────────────┘    │  Namespace: clusters-hosted      │   │
│                             │  ┌──────────┐ ┌──────┐ ┌──────┐ │   │
│                             │  │kube-api  │ │ etcd │ │ ctrl │ │   │
│                             │  │server pod│ │ pod  │ │ pods │ │   │
│                             │  └──────────┘ └──────┘ └──────┘ │   │
│                             └──────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Tailscale Subnet Router · mTLS · 100.x.x.x                 │  │
│  └──────────────────────────┬─────────────────────────────────-┘  │
└────────────────────────────-┼───────────────────────────────────---┘
                              │ mTLS (Tailscale WireGuard)
                ┌─────────────▼──────────────────┐
                │        Azure Workers            │
                │        westeurope               │
                │                                 │
                │  ┌───────────┐                  │
                │  │ worker-1  │                  │
                │  │ FCOS      │                  │
                │  │ D4s_v3    │                  │
                │  │ Spot      │                  │
                │  └───────────┘                  │
                │  NodePool autoscaling: 1 → 5    │
                │  Tailscale ephemeral agent       │
                └────────────────────────────────┘

         Harbor VM · harbor.okd.lab
         Trivy · Cosign · Supply Chain Security
```

---

## The HyperShift Model — Control Plane vs Data Plane

HyperShift decouples the Control Plane from the Data Plane. The entire Hosted Cluster Control Plane runs as **pods on OKD SNO**, while Azure Spot VMs handle only the data plane.

| Component | Location |
|---|---|
| `kube-apiserver` | Pod on `sno-master` |
| `etcd` | Pod on `sno-master` |
| `kube-controller-manager` | Pod on `sno-master` |
| `kube-scheduler` | Pod on `sno-master` |
| Azure Workers | Data plane only — D4s_v3 Spot |

---

## Stack Overview

### Management Cluster — OKD SNO 4.15

| Component | Purpose | Status |
|---|---|---|
| ArgoCD | GitOps engine — all deployments | ✅ Deployed |
| Keycloak | OIDC SSO for cluster and applications | ✅ Deployed |
| HashiCorp Vault | Secrets management + Kubernetes auth | ✅ Deployed |
| External Secrets Operator | Vault → Kubernetes secrets sync | ✅ Deployed |
| ClusterSecretStore | Cross-namespace secrets for HyperShift | ✅ Phase 2b |
| Grafana + Loki | Observability stack | ✅ Deployed |
| Kyverno | Policy engine — admission control | ✅ Deployed |
| GitHub Actions Runner | Self-hosted CI on OKD | ✅ Deployed |
| HyperShift Operator | Hosted Control Planes manager | ✅ Phase 1 |
| Tailscale Subnet Router | Secure tunnel to Azure workers | ✅ Phase 2 |

---

## Project Phases

### ✅ Phase 1 — HyperShift Operator Installation
- HyperShift CLI installed from `quay.io/hypershift/hypershift-operator:latest`
- CRDs patched for Kubernetes 1.28 compatibility (CEL `isIP()` removed via Python script)
- Applied via `--server-side --force-conflicts` to bypass 262144 bytes annotation limit
- Operator running with 2 replicas in namespace `hypershift`

### ✅ Phase 2 — Tailscale Zero Trust Network
- Tailscale DaemonSet deployed on `sno-master` (privileged, hostNetwork)
- Dedicated ServiceAccount + RBAC + SCC `privileged`
- `sno-master` connected to tailnet with Subnet Router
- Subnet `<sno-subnet>/24` advertised and approved
- DERP relay: Frankfurt (fra) — optimal for westeurope Azure region

### ✅ Phase 2b — Secrets Management (Vault → ESO → Kubernetes)
- Vault Kubernetes auth backend enabled and configured with OKD SNO CA cert
- Vault policies + roles created (least-privilege): `keycloak`, `grafana`, `eso-hypershift`
- ESO SecretStores fixed: `keycloak` + `grafana-operator` → `Valid/Ready`
- ExternalSecrets synced: `keycloak-secrets` + `grafana-prometheus-token` → `SecretSynced`
- `ClusterSecretStore vault-cluster-backend` created (cross-namespace for HyperShift)
- Tailscale auth key secured: `Vault KV → ESO → K8s Secret (namespace clusters)`
- Azure SP credentials secured: `Vault KV → ESO → K8s Secret (namespace clusters)`
- **No secrets in Git** — all credentials managed via Vault + ESO

### ✅ Phase 3 — Azure HostedCluster Creation (partial)
- Azure Service Principal created with `Contributor` role + immediate credential rotation
- Azure infrastructure provisioned via **Terraform** (`infra/azure/`):
  - VNet, Subnet, NSG (Tailscale UDP 41641 + HTTPS TCP 443)
- 7 Workload Identity Managed Identities created via `hypershift create iam azure`
- OIDC issuer endpoint deployed on Azure Blob Storage
- HostedCluster CR applied → HCP pods started on SNO:
  - `control-plane-operator` ✅ Running
  - `cluster-api` ✅ Running
  - `capi-provider` ⏳ Init (blocked — see ADR-001)
- OVN-Kubernetes egress fix: `routingViaHost: true` (pods → internet access)
- **ADR-001**: HyperShift Azure requires public LB for kube-apiserver —
  incompatible with homelab (no public IP). See `docs/adr/ADR-001-hypershift-azure-lb.md`

### 🔜 Phase 4 — Supply Chain Security
- Configure Harbor as pull-through cache for Hosted Cluster images
- Enforce Cosign signature verification via Kyverno on the Hosted Cluster
- Integrate Trivy scanning in GitHub Actions CI pipeline

### 🔜 Phase 5 — Observability & IAM
- Extend Prometheus/Grafana to scrape Hosted Cluster metrics
- Federate Loki logs from Azure workers to OKD SNO
- Configure Keycloak OIDC for Hosted Cluster API authentication

### 🔜 Phase 6 — Tailscale Funnel (ADR-001 resolution)
- Expose HCP kube-apiserver via Tailscale Funnel (public HTTPS endpoint)
- Eliminates need for Azure public Load Balancer
- Workers join HCP via Tailscale — Zero Trust end-to-end

---

## Repository Structure

```
okd-hypershift-security-platform/
├── argocd/
│   └── applications/
│       └── eso-hypershift.yaml         # ClusterSecretStore ArgoCD app
├── infra/
│   └── azure/                          # Terraform — Azure network infra
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       ├── versions.tf
│       └── README.md
├── manifests/
│   ├── eso/
│   │   ├── cluster-secret-store.yaml
│   │   ├── externalsecret-tailscale.yaml
│   │   └── externalsecret-azure.yaml
│   ├── hypershift/
│   │   ├── hypershift-install-patched.yaml
│   │   ├── hosted-cluster.yaml
│   │   └── nodepool.yaml
│   └── tailscale/
│       └── daemonset-sno.yaml
├── scripts/
│   └── deploy-hostedcluster.sh         # Injects secrets from ESO at deploy time
├── docs/
│   ├── architecture/
│   │   └── architecture-overview.svg
│   ├── demo/
│   │   ├── DEMO.md
│   │   └── screenshots/                # Flat structure — no subdirectories
│   ├── adr/
│   │   └── ADR-001-hypershift-azure-lb.md
│   └── phase2b-secrets-hypershift.md
├── SECURITY.md
└── README.md
```

---

## Key Technical Challenges & Solutions

| Challenge | Solution |
|---|---|
| HyperShift CEL `isIP()` incompatible with k8s 1.28 | Python script to patch CRDs before apply |
| CRD too large for client-side apply (>262144 bytes) | `--server-side --force-conflicts` apply |
| MCE not available on OKD | HyperShift standalone operator via CLI |
| Tailscale DNS resolution fails with `hostNetwork: true` | `dnsPolicy: ClusterFirstWithHostNet` |
| Tailscale pod rejected by OKD PodSecurity | Dedicated ServiceAccount + SCC `privileged` |
| Vault Kubernetes auth not enabled | `vault auth enable kubernetes` + CA cert config |
| ESO `403 permission denied` on SecretStores | Role bound to `cluster-external-secrets` SA |
| OVN-Kubernetes pods no internet egress | `routingViaHost: true` patch on network.operator |
| HyperShift Azure always creates public LB | ADR-001 — Tailscale Funnel planned (Phase 6) |
| Azure SP credentials exposed | Immediate rotation via `az ad sp credential reset` |

---

## Demo Walkthrough

A full step-by-step demo with screenshots is available in [`docs/demo/DEMO.md`](docs/demo/DEMO.md).

---

## Author

**Stéphane Seloi** — Freelance Cloud Native Security Architect  
GitHub: [Z3ROX-lab](https://github.com/Z3ROX-lab)  
Certifications: CCSP · AWS Solutions Architect · ISO 27001 Lead Implementer · CompTIA Security+

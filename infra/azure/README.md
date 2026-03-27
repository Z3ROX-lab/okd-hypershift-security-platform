# Infrastructure Azure — HyperShift NodePool

Terraform pour provisionner l'infrastructure réseau Azure nécessaire
au HostedCluster HyperShift avec workers Spot en `westeurope`.

## Ressources créées

| Ressource | Nom | Description |
|-----------|-----|-------------|
| Resource Group | rg-hypershift-okd-azure-nodepools | Conteneur de toutes les ressources |
| Virtual Network | vnet-hypershift | VNet 10.0.0.0/16 |
| Subnet | subnet-workers | Subnet workers 10.0.1.0/24 |
| NSG | nsg-hypershift-workers | Règles Tailscale + HTTPS + SSH (voir détail ci-dessous) |

## Règles NSG — nsg-hypershift-workers

### Inbound (trafic entrant vers les workers Azure)

| Priorité | Nom | Protocole | Port | Source | Justification |
|----------|-----|-----------|------|--------|---------------|
| 100 | AllowTailscaleInbound | UDP | 41641 | * | Tunnel Tailscale entre workers et management cluster. Port fixe utilisé par le daemon Tailscale pour établir les connexions WireGuard directes. Nécessaire pour que le worker rejoigne le réseau Tailscale au démarrage. |
| 110 | AllowHTTPSInbound | TCP | 443 | 100.64.0.0/10 | Communication kubelet → kube-apiserver du Hosted Control Plane. Le HCP tourne comme pod sur le SNO, accessible via son IP Tailscale (CGNAT 100.64.0.0/10). Sans cette règle, le worker ne peut pas s'enregistrer auprès du control plane. |
| 120 | AllowSSHDebug | TCP | 22 | 100.64.0.0/10 | Accès SSH de debug depuis le management cluster uniquement, restreint au réseau Tailscale. Permet `oc debug node/<worker>` et accès SSH direct depuis sno-master. |
| 65000 | AllowVnetInBound | * | * | VirtualNetwork | Règle implicite Azure — trafic intra-VNet autorisé. |
| 65001 | AllowAzureLoadBalancerInBound | * | * | AzureLoadBalancer | Règle implicite Azure — health checks du Load Balancer. |
| 65500 | DenyAllInBound | * | * | * | Règle implicite Azure — tout le reste bloqué. |

### Outbound (trafic sortant depuis les workers Azure)

| Priorité | Nom | Protocole | Port | Destination | Justification |
|----------|-----|-----------|------|-------------|---------------|
| 65000 | AllowVnetOutBound | * | * | VirtualNetwork | Règle implicite Azure — trafic intra-VNet autorisé. |
| 65001 | AllowInternetOutBound | * | * | Internet | Règle implicite Azure — sortie internet autorisée. Nécessaire pour : pull images OKD (quay.io), installation Tailscale, mises à jour OS. |
| 65500 | DenyAllOutBound | * | * | * | Règle implicite Azure — tout le reste bloqué. |

> **Note** : Les règles outbound implicites Azure sont suffisantes pour notre usage.
> Tailscale établit les tunnels WireGuard en outbound (UDP 41641 vers les DERP servers
> puis direct peer-to-peer), ce qui est couvert par `AllowInternetOutBound`.

### Architecture réseau simplifiée

```
Worker Azure (10.0.1.x)
  │
  ├── Outbound UDP 41641 → Tailscale DERP servers (Internet)
  │     → établit le tunnel WireGuard
  │     → worker visible sur réseau 100.x.x.x
  │
  ├── Outbound TCP 443 → kube-apiserver HCP (100.x.x.x via Tailscale)
  │     → kubelet s'enregistre auprès du control plane
  │     → worker passe en état Ready
  │
  └── Outbound TCP/UDP → quay.io, registry (Internet)
        → pull des images OKD au démarrage
```

## Prérequis

- Terraform >= 1.5.0
- Azure CLI configuré (`az login`)
- Service Principal HyperShift créé (stocké dans Vault)

## Usage

```bash
cd infra/azure

# 1. Exporter les credentials Azure SP depuis Vault
export ARM_CLIENT_ID="$(vault kv get -field=client-id secret/hypershift/azure)"
export ARM_CLIENT_SECRET="$(vault kv get -field=client-secret secret/hypershift/azure)"
export ARM_TENANT_ID="$(vault kv get -field=tenant-id secret/hypershift/azure)"
export ARM_SUBSCRIPTION_ID="$(vault kv get -field=subscription-id secret/hypershift/azure)"

# Variables Terraform
export TF_VAR_subscription_id="$ARM_SUBSCRIPTION_ID"
export TF_VAR_tenant_id="$ARM_TENANT_ID"

# 2. Initialiser
terraform init

# 3. Planifier
terraform plan

# 4. Appliquer
terraform apply

# 5. Récupérer les IDs pour le manifest HostedCluster
terraform output hostedcluster_azure_config
```

## Teardown

```bash
terraform destroy
```

> ⚠️ Le teardown supprime toutes les ressources Azure — s'assurer que
> le HostedCluster est déjà supprimé avant (`oc delete hostedcluster okd-azure-nodepools`).

## Fichiers à ne jamais committer

```
*.tfvars
*.tfstate
*.tfstate.backup
.terraform/
.terraform.lock.hcl
```

# Infrastructure Azure — HyperShift NodePool

Terraform pour provisionner l'infrastructure réseau Azure nécessaire
au HostedCluster HyperShift avec workers Spot en `westeurope`.

## Ressources créées

| Ressource | Nom | Description |
|-----------|-----|-------------|
| Resource Group | rg-hypershift-okd-azure-nodepools | Conteneur de toutes les ressources |
| Virtual Network | vnet-hypershift | VNet 10.0.0.0/16 |
| Subnet | subnet-workers | Subnet workers 10.0.1.0/24 |
| NSG | nsg-hypershift-workers | Règles Tailscale + HTTPS + SSH |

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

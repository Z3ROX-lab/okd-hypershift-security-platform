#!/bin/bash
# =============================================================================
# deploy-hostedcluster.sh — Déploiement HostedCluster HyperShift Azure
# Injecte les variables sensibles depuis K8s Secret (ESO → Vault)
# Usage : ./scripts/deploy-hostedcluster.sh [apply|delete]
# =============================================================================
set -euo pipefail

ACTION=${1:-apply}
MANIFEST="manifests/hypershift/hosted-cluster.yaml"

echo "=== HyperShift HostedCluster Deploy ==="
echo "Action: $ACTION"
echo ""

# -----------------------------------------------------------------------------
# 1. Récupérer les credentials Azure depuis ESO (Vault → K8s Secret)
# -----------------------------------------------------------------------------
echo "→ Fetching Azure credentials from ESO secret..."

export AZURE_SUBSCRIPTION_ID=$(oc get secret azure-credentials -n clusters \
  -o jsonpath='{.data.AZURE_SUBSCRIPTION_ID}' | base64 -d)
export AZURE_TENANT_ID=$(oc get secret azure-credentials -n clusters \
  -o jsonpath='{.data.AZURE_TENANT_ID}' | base64 -d)

# Vérifier que les credentials sont là
if [ -z "$AZURE_SUBSCRIPTION_ID" ] || [ -z "$AZURE_TENANT_ID" ]; then
  echo "❌ ERROR: Azure credentials not found in namespace clusters"
  echo "   Run: oc get externalsecret azure-credentials -n clusters"
  exit 1
fi

# -----------------------------------------------------------------------------
# 2. Récupérer les IDs des ressources Azure depuis Terraform outputs
# -----------------------------------------------------------------------------
echo "→ Fetching Azure resource IDs from Terraform outputs..."

TERRAFORM_DIR="infra/azure"

if [ ! -f "$TERRAFORM_DIR/terraform.tfstate" ]; then
  echo "❌ ERROR: Terraform state not found in $TERRAFORM_DIR"
  echo "   Run: cd $TERRAFORM_DIR && terraform apply"
  exit 1
fi

# Injecter credentials Terraform depuis ESO
export ARM_CLIENT_ID=$(oc get secret azure-credentials -n clusters \
  -o jsonpath='{.data.AZURE_CLIENT_ID}' | base64 -d)
export ARM_CLIENT_SECRET=$(oc get secret azure-credentials -n clusters \
  -o jsonpath='{.data.AZURE_CLIENT_SECRET}' | base64 -d)
export ARM_TENANT_ID="$AZURE_TENANT_ID"
export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"

export AZURE_RESOURCE_GROUP=$(cd "$TERRAFORM_DIR" && terraform output -raw resource_group_name)
export AZURE_VNET_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw vnet_id)
export AZURE_SUBNET_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw subnet_id)
export AZURE_NSG_ID=$(cd "$TERRAFORM_DIR" && terraform output -raw nsg_id)

echo "   ✅ RESOURCE_GROUP : $AZURE_RESOURCE_GROUP"
echo "   ✅ VNET_ID        : $(echo $AZURE_VNET_ID | cut -c1-40)..."
echo "   ✅ SUBNET_ID      : $(echo $AZURE_SUBNET_ID | cut -c1-40)..."
echo "   ✅ NSG_ID         : $(echo $AZURE_NSG_ID | cut -c1-40)..."

# -----------------------------------------------------------------------------
# 3. Substituer les variables et appliquer
# -----------------------------------------------------------------------------
echo ""
echo "→ Substituting variables in $MANIFEST..."

RENDERED=$(envsubst < "$MANIFEST")

if [ "$ACTION" = "apply" ]; then
  echo "→ Applying HostedCluster CR..."
  echo "$RENDERED" | oc apply -f -
  echo ""
  echo "✅ HostedCluster applied — monitoring:"
  echo "   oc get hostedcluster okd-azure-nodepools -n clusters -w"
  echo "   oc get pods -n clusters-okd-azure-nodepools -w"

elif [ "$ACTION" = "delete" ]; then
  echo "→ Deleting HostedCluster CR..."
  echo "$RENDERED" | oc delete -f - --ignore-not-found
  echo "✅ HostedCluster deleted"
  echo "   Workers Azure seront supprimés automatiquement"
  echo "   Penser à: cd infra/azure && terraform destroy"

else
  echo "❌ Unknown action: $ACTION"
  echo "   Usage: $0 [apply|delete]"
  exit 1
fi

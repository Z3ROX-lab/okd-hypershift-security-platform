# =============================================================================
# outputs.tf — IDs des ressources Azure créées
# Ces valeurs sont nécessaires pour le manifest HostedCluster CR
# =============================================================================

output "resource_group_id" {
  description = "Resource Group ID"
  value       = azurerm_resource_group.hypershift.id
}

output "resource_group_name" {
  description = "Resource Group name"
  value       = azurerm_resource_group.hypershift.name
}

output "vnet_id" {
  description = "VNet full resource ID — à utiliser dans HostedCluster.spec.platform.azure.vnetID"
  value       = azurerm_virtual_network.hypershift.id
}

output "subnet_id" {
  description = "Subnet full resource ID — à utiliser dans HostedCluster.spec.platform.azure.subnetID"
  value       = azurerm_subnet.workers.id
}

output "nsg_id" {
  description = "NSG full resource ID — à utiliser dans HostedCluster.spec.platform.azure.securityGroupID"
  value       = azurerm_network_security_group.workers.id
}

output "hostedcluster_azure_config" {
  description = "Bloc azure prêt à copier dans le manifest HostedCluster CR"
  value = <<-EOT

    # Copier ce bloc dans manifests/hypershift/hosted-cluster.yaml
    # spec.platform.azure:
      location: ${azurerm_resource_group.hypershift.location}
      resourceGroup: ${azurerm_resource_group.hypershift.name}
      subscriptionID: ${var.subscription_id}
      tenantID: ${var.tenant_id}
      vnetID: ${azurerm_virtual_network.hypershift.id}
      subnetID: ${azurerm_subnet.workers.id}
      securityGroupID: ${azurerm_network_security_group.workers.id}
  EOT
  sensitive = true
}

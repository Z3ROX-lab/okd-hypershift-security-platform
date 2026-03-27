variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
  sensitive   = true
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group name for HyperShift infra"
  type        = string
  default     = "rg-hypershift-okd-azure-nodepools"
}

variable "vnet_name" {
  description = "Virtual Network name"
  type        = string
  default     = "vnet-hypershift"
}

variable "vnet_address_space" {
  description = "VNet address space"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_name" {
  description = "Workers subnet name"
  type        = string
  default     = "subnet-workers"
}

variable "subnet_prefix" {
  description = "Workers subnet CIDR"
  type        = string
  default     = "10.0.1.0/24"
}

variable "nsg_name" {
  description = "Network Security Group name"
  type        = string
  default     = "nsg-hypershift-workers"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    project     = "okd-hypershift-security-platform"
    environment = "homelab"
    managed-by  = "terraform"
    owner       = "Z3ROX-lab"
  }
}

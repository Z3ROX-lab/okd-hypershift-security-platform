terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

provider "azurerm" {
  features {}
  # Credentials via variables d'environnement :
  # ARM_CLIENT_ID       = SP client-id
  # ARM_CLIENT_SECRET   = SP client-secret
  # ARM_TENANT_ID       = tenant-id
  # ARM_SUBSCRIPTION_ID = subscription-id
}

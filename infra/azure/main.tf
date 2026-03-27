# =============================================================================
# main.tf — Infrastructure Azure pour HyperShift NodePool
# Repo : okd-hypershift-security-platform
# Managed by : Terraform >= 1.5.0
# =============================================================================

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "hypershift" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# -----------------------------------------------------------------------------
# Virtual Network
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "hypershift" {
  name                = var.vnet_name
  resource_group_name = azurerm_resource_group.hypershift.name
  location            = azurerm_resource_group.hypershift.location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

# -----------------------------------------------------------------------------
# Network Security Group
# Règles minimales pour HyperShift + Tailscale
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "workers" {
  name                = var.nsg_name
  resource_group_name = azurerm_resource_group.hypershift.name
  location            = azurerm_resource_group.hypershift.location
  tags                = var.tags

  # Tailscale — UDP 41641
  # Workers Azure → SNO management cluster via Tailscale mesh
  security_rule {
    name                       = "AllowTailscaleInbound"
    priority                   = 100
    protocol                   = "Udp"
    access                     = "Allow"
    direction                  = "Inbound"
    source_port_range          = "*"
    destination_port_range     = "41641"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # HTTPS 443 — kubelet workers → kube-apiserver HCP (pod sur SNO)
  # Trafic via Tailscale donc source = Tailscale CGNAT 100.64.0.0/10
  security_rule {
    name                       = "AllowHTTPSInbound"
    priority                   = 110
    protocol                   = "Tcp"
    access                     = "Allow"
    direction                  = "Inbound"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "100.64.0.0/10"
    destination_address_prefix = "*"
  }

  # SSH 22 — debug uniquement, source restreinte
  security_rule {
    name                       = "AllowSSHDebug"
    priority                   = 120
    protocol                   = "Tcp"
    access                     = "Allow"
    direction                  = "Inbound"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "100.64.0.0/10"
    destination_address_prefix = "*"
  }
}

# -----------------------------------------------------------------------------
# Subnet workers
# -----------------------------------------------------------------------------
resource "azurerm_subnet" "workers" {
  name                 = var.subnet_name
  resource_group_name  = azurerm_resource_group.hypershift.name
  virtual_network_name = azurerm_virtual_network.hypershift.name
  address_prefixes     = [var.subnet_prefix]
}

# -----------------------------------------------------------------------------
# Associer NSG → Subnet
# -----------------------------------------------------------------------------
resource "azurerm_subnet_network_security_group_association" "workers" {
  subnet_id                 = azurerm_subnet.workers.id
  network_security_group_id = azurerm_network_security_group.workers.id
}

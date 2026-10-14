// =============================================================================
// Virtual Network Module
// =============================================================================
// Creates a VNet with subnets for AKS and other services. Network configuration
// is important for SRE Agent - ensure the cluster is not completely isolated
// from inbound traffic to allow SRE Agent access.
// =============================================================================

@description('Name of the virtual network')
param vnetName string

@description('Azure region for deployment')
param location string

@description('Tags to apply to resources')
param tags object

@description('Address prefix for the VNet')
param addressPrefix string = '10.0.0.0/16'

@description('Address prefix for the AKS subnet')
param aksSubnetPrefix string = '10.0.0.0/22'

@description('Address prefix for services subnet (private endpoints)')
param servicesSubnetPrefix string = '10.0.4.0/24'

// =============================================================================
// RESOURCES
// =============================================================================

// This NSG is attached to the AKS subnet by the environment's network policy.
resource aksNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' existing = {
  name: '${vnetName}-snet-aks-nsg-${location}'
}

resource allowNodePorts 'Microsoft.Network/networkSecurityGroups/securityRules@2024-01-01' = {
  parent: aksNsg
  name: 'allow-internet-nodeports'
  properties: {
    description: 'Allow public LoadBalancer traffic to Kubernetes NodePorts'
    priority: 1000
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: 'Internet'
    sourcePortRange: '*'
    destinationAddressPrefix: aksSubnetPrefix
    destinationPortRange: '30000-32767'
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-aks'
        properties: {
          addressPrefix: aksSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-services'
        properties: {
          addressPrefix: servicesSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

// =============================================================================
// OUTPUTS
// =============================================================================

output vnetId string = vnet.id
output vnetName string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
output servicesSubnetId string = vnet.properties.subnets[1].id

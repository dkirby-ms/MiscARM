@description('The name of you Virtual Machine')
param vmName string = 'Ag-K3s-${namingGuid}'

@description('Username for the Virtual Machine')
param adminUsername string = 'agora'

@description('RSA public key used for securing SSH access to ArcBox resources. This parameter is only needed when deploying the DataOps or DevOps flavors.')
@secure()
param sshRSAPublicKey string = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDEDSGpc6dYAmurlE8eUOX0ZaZf9bUDnahX8X2qreYXMcGyVoodMLoqQEjyL/bMlAKzVPJYk2gGMLUT7nz55uPqo63xTu4Ix5dNg8JXSCySrJpoTDpSdb2fzH2XuROjuoTXuOC4Q2YMnB5pxH/M1+MXyqOhkmouMkNTlWbwFZjHBo0dXEdEC9tp5pKn74kVwWfZuS4+Jw/JUwX7rpZSwCtKiMI22BpKLT9oirhQIRUFLwboYC2jdo7b+pUbdZQOoQQ82hHbnxEd1bcnHoczxO0j6NeZ6rA9BzsCpbK7ujFrAXRya1XJmuLlf9kug+pdMKSLOrSnpfjx5eg2C/sL8hBydpilK+6M5cJx63trHzz/kySxW1I2C8GERjCKXqLNIR/W2L5+7yl7BP8Sz1A1FmGFz8BpXULsYStiWZM1FEuBTxoHaNWDvUHAy0SpLPKUSo1oLxsP2hX/z2X88d/webIKHn4EWJFRWBpr8HjJu26qmLcxhywjSMkJSVMXr6G2Rtql7z5TWHgSGijgGBJGm30ehKHAETYArw6OByhpL7zXv5/vOX+u98KFvt6wwVqKni89FHRywn25Ym8wQeHfzR/Yjd1+eP1IqMI8essgFWYmy26Nae5Z1ovYDNbxYezWD9shAg1We4XHWx91S7GCF7Ml1KlDhojle4lz1xL2kJQVbQ== dakir@microsoft.com'

@description('The Ubuntu version for the VM. This will pick a fully patched image of this given Ubuntu version')
@allowed([
  '22_04-lts-gen2'
])
param ubuntuOSVersion string = '22_04-lts-gen2'

@description('Location for all resources.')
param azureLocation string = resourceGroup().location

@description('The size of the VM')
param vmSize string = 'Standard_D16s_v5'

@maxLength(5)
@description('Random GUID')
param namingGuid string = toLower(substring(newGuid(), 0, 5))

@description('Name of the Cloud VNet')
param virtualNetworkNameCloud string = 'vnet1'

@description('Name of the K3s subnet in the cloud virtual network')
param subnetNameCloudK3s string = 'subnet-k3s'

@description('Name of the inner-loop subnet in the cloud virtual network')
param subnetNameCloud string = 'subnet-cloud'

@description('Azure Region to deploy the Log Analytics Workspace')
param location string = resourceGroup().location

@description('Resource tag for Jumpstart Agora')
param resourceTags object = {
  Project: 'Jumpstart_Agora'
}

@description('Name of the prod Network Security Group')
param networkSecurityGroupNameCloud string = 'Ag-NSG-Prod'

var addressPrefixCloud = '10.16.0.0/16'
var subnetAddressPrefixK3s = '10.16.80.0/21'
var subnetAddressPrefixCloud = '10.16.64.0/21'
var networkInterfaceName = '${vmName}-NIC'
var osDiskType = 'Premium_LRS'
var diskSize = 512
var numberOfIPAddresses =  15 // The number of IP addresses to create
var cloudK3sSubnet = [
  {
    name: subnetNameCloudK3s
    properties: {
      addressPrefix: subnetAddressPrefixK3s
      privateEndpointNetworkPolicies: 'Enabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
      networkSecurityGroup: {
        id: networkSecurityGroupCloud.id
      }
    }
  }
]
var cloudSubnet = [
  {
    name: subnetNameCloud
    properties: {
      addressPrefix: subnetAddressPrefixCloud
      privateEndpointNetworkPolicies: 'Enabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
      networkSecurityGroup: {
        id: networkSecurityGroupCloud.id
      }
    }
  }
]

// Create multiple NIC IP configurations and assign the public IP to the IP configuration
resource networkInterface 'Microsoft.Network/networkInterfaces@2022-01-01' = {
  name: networkInterfaceName
  location: azureLocation
  properties: {
    ipConfigurations: [for i in range(1, numberOfIPAddresses): {
      name: 'ipconfig${i}'
      properties: {
        subnet: {
          id: cloudVirtualNetwork.properties.subnets[0].id
        }
        privateIPAllocationMethod: 'Dynamic'
        primary: i == 1 ? true : false
      }
    }]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2022-03-01' = {
  name: vmName
  location: azureLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      osDisk: {
        name: '${vmName}-OSDisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
        diskSizeGB: diskSize
      }
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: ubuntuOSVersion
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshRSAPublicKey
            }
          ]
        }
      }
    }
  }
}

// Add role assignment for the VM: Owner role
resource vmRoleAssignment_Owner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, 'Microsoft.Authorization/roleAssignments', 'Owner')
  scope: resourceGroup()
  properties: {
    principalId: vm.identity.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
    principalType: 'ServicePrincipal'
  }
}

// Add role assignment for the VM: Storage Blob Data Contributor
resource vmRoleAssignment_Storage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, 'Microsoft.Authorization/roleAssignments', 'Storage Blob Data Contributor')
  scope: resourceGroup()
  properties: {
    principalId: vm.identity.principalId
    roleDefinitionId: resourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalType: 'ServicePrincipal'
  }
}



resource cloudVirtualNetwork 'Microsoft.Network/virtualNetworks@2022-07-01' = {
  name: virtualNetworkNameCloud
  location: location
  tags: resourceTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefixCloud
      ]
    }
    subnets: union (cloudK3sSubnet,cloudSubnet)
  }
}

resource networkSecurityGroupCloud 'Microsoft.Network/networkSecurityGroups@2023-02-01' = {
  name: networkSecurityGroupNameCloud
  location: location
  tags: resourceTags
  properties: {
    securityRules: []
  }
}

output vnetId string = cloudVirtualNetwork.id
output k3sSubnetId string = cloudVirtualNetwork.properties.subnets[0].id
output cloudSubnetId string = cloudVirtualNetwork.properties.subnets[1].id
output virtualNetworkNameCloud string = cloudVirtualNetwork.name

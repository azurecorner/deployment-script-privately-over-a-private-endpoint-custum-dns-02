@description('Specify a project name that is used for generating resource names.')
param projectName string='datasynchro'

@description('Specify the resource location.')
param location string = resourceGroup().location

@description('Specify the container image.')
param containerImage string = 'mcr.microsoft.com/azuredeploymentscripts-powershell:az9.7'

@description('Specify the mount path.')
param mountPath string = '/mnt/azscripts/azscriptinput'
param userAssignedIdentityName string = '${projectName}-identity'

var storageAccountName = toLower('${projectName}store')
var fileShareName = '${projectName}share'
var containerGroupName = '${projectName}cg'
var containerName = '${projectName}container'
var roleNameStorageFileDataPrivilegedContributor = '69566ab7-960f-475b-8e7c-b3118f30c6bd'

/*  ------------------------------------------ Storage Account ------------------------------------------ */

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

/*  ------------------------------------------ File Share  ------------------------------------------ */

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: '${storageAccountName}/default/${fileShareName}'
  dependsOn: [
    storageAccount
  ]
}

/*  ------------------------------------------ Contianer Group ------------------------------------------ */
 resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}' : {}
    }
  }
  properties: {

    subnetIds: [
      {
        id: virtualNetwork::containerInstanceSubnet.id
      }
    ]
    containers: [
      {
        name: containerName
        properties: {
          image: containerImage
          resources: {
            requests: {
              cpu: 1
              memoryInGB: json('1.5')
            }
          }
          ports: [
            {
              protocol: 'TCP'
              port: 80
            }
          ]
          volumeMounts: [
            {
              name: 'filesharevolume'
              mountPath: mountPath
            }
          ]
      
          
           command: [
            '/bin/sh'
            '-c'
            'cd /mnt/azscripts/azscriptinput && [ -f hello.ps1 ] && pwsh ./hello.ps1 || echo "File (hello.ps1) not found, please upload file (hello.ps1) in storage account (datasynchrostore) fileshare (datasynchroshare) and restart the container "; pwsh -c "Start-Sleep -Seconds 1800"'
          ] 
          
        }
      }
    ]
   
    osType: 'Linux'
    volumes: [
      {
        name: 'filesharevolume'
        azureFile: {
          readOnly: false
          shareName: fileShareName
          storageAccountName: storageAccountName
          storageAccountKey: storageAccount.listKeys().keys[0].value
        }
      }
    ]
    
    dnsConfig: {
      nameServers: [
       '10.0.3.70'
      ]
  }


  }
} 

/*  ------------------------------------------ Virtual Network ------------------------------------------ */
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'container-dns-vnet'
  location: location
  properties:{
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }

    dhcpOptions: {
      dnsServers: [
       '10.0.3.70'
      ]
    }
  }

 resource privateEndpointSubnet 'subnets' = {
    name: 'PrivateEndpointSubnet'
    properties: {
      addressPrefixes: [
        '10.0.1.0/24'
      ]
    }
  }

  resource containerInstanceSubnet 'subnets' = {
    name: 'ContainerInstanceSubnet'
    properties: {
      addressPrefix: '10.0.2.0/24'
      delegations: [
        {
          name: 'containerDelegation'
          properties: {
            serviceName: 'Microsoft.ContainerInstance/containerGroups'
          }
        }
      ]
    }
  }

  resource privateResolverInboundSubnet 'subnets' = {
    name: 'privateResolverInboundSubnet'
    properties: {
      addressPrefix: '10.0.3.0/24'
      delegations: [
        {
          name: 'privateResolverDelegation'
          properties: {
            serviceName: 'Microsoft.Network/dnsResolvers'
          }
        }
      ]
    }
  }
}

/*  ------------------------------------------ Private Endpoint ------------------------------------------ */
resource privateEndpointStorageFile 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccount.name}'
  location: location
  properties: {
   privateLinkServiceConnections: [
     {
       name: storageAccount.name
       properties: {
         privateLinkServiceId: storageAccount.id
         groupIds: [
           'file'
         ]
       }
     }
   ]
   customNetworkInterfaceName: '${storageAccount.name}-nic'
   subnet: {
     id: virtualNetwork::privateEndpointSubnet.id
   }
  }
  dependsOn: [
     virtualNetwork
  ]
}

/*  ------------------------------------------- private dns zone group  ------------------------------------------ */
resource privateEndpointStorageFilePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2022-05-01' = {
  parent: privateEndpointStorageFile
  name: 'filePrivateDnsZoneGroup'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: {
          privateDnsZoneId: privateStorageFileDnsZone.id
        }
      }
    ]
  }
}


/*  ------------------------------------------ Private DNS Zone ------------------------------------------ */
resource privateStorageFileDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.file.core.windows.net'
  location: 'global'

  resource virtualNetworkLink 'virtualNetworkLinks' = {
    name: uniqueString(virtualNetwork.name)
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: virtualNetwork.id
      }
    }
  }


}

/*  ------------------------------------------ Managed Identity ------------------------------------------ */
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: userAssignedIdentityName
  location: location
}

/*  ------------------------------------------ Role Assignment ------------------------------------------ */
resource storageFileDataPrivilegedContributorReference 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: roleNameStorageFileDataPrivilegedContributor
  scope: tenant()
}


resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageFileDataPrivilegedContributorReference.id, managedIdentity.id, storageAccount.id)
  scope: storageAccount
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: storageFileDataPrivilegedContributorReference.id
    principalType: 'ServicePrincipal'
  }
}

/*  ------------------------------------------ Private Resolver ------------------------------------------ */

resource privateResolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: 'privateResolver'
  location: location
  properties: {
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
  dependsOn: [
    virtualNetwork
  ]
}

resource inboundEndpoint 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  name: 'inboundEndpoint'
  location: location
  parent: privateResolver
  properties: {
    ipConfigurations: [
      {
        privateIpAddress: '10.0.3.70'
        privateIpAllocationMethod: 'Static'
        subnet: {
          id: virtualNetwork::privateResolverInboundSubnet.id
        }
      }
    ]
  }
}

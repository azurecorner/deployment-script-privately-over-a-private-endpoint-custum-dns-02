# Run Deployment Script Privately in Azure Over Private Endpoint and Custom DNS Server Using Bicep


## 1. Overview
Azure Deployment Scripts allow you to run PowerShell or Azure CLI scripts during a Bicep deployment. This is useful for tasks like configuring resources, retrieving values, or executing custom logic.  
[Learn more about Deployment Scripts in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-script-bicep?tabs=CLI)

In my previous tutorial, I provided an introduction to Azure deployment scripts: Run Script in Azure Using Deployment Scripts and Bicep (https://logcorner.com/run-script-in-azure-using-deployment-scripts-and-bicep/)


The deployment script service requires both a Storage Account and an Azure Container Instance.

In a private environment, you can use an existing Storage Account with a private endpoint enabled. However, a deployment script requires a new Azure Container Instance and cannot use an existing one.

For more details on running a Bicep deployment script privately over a private endpoint, refer to this article: Run Bicep Deployment Script Privately (https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-script-vnet-private-endpoint).

In the article linked above, the Azure Container Instance resource is created automatically by the deployment script. But what happens if you use a custom DNS server? The limitation is that you cannot use a custom DNS server because the ACI is created automatically, and the only configurable option is the container group name.

In this tutorial, I will demonstrate how to use a custom DNS server to run a script in Azure.

---
To run deployment scripts privately, you need the following infrastructure:

- **A virtual network with two subnets:**
  - One subnet for the private endpoint.
  - One subnet for the Azure Container Instance (ACI) with **Microsoft.ContainerInstance/containerGroups** delegation.

- **A storage account** with public network access disabled.

- **A private endpoint** within the virtual network, configured with the **file** sub-resource on the storage account.

- **A private DNS zone** (`privatelink.file.core.windows.net`) linked to the created virtual network.

- **An Azure Container Group** attached to the ACI subnet, with a volume linked to the storage account file share.

- **A user-assigned managed identity** with **Storage File Data Privileged Contributor** permissions on the storage account, specified in the **identity** property of the container group resource.


---

## 2. Infrastructure

```bicep
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

```

 

#### **Virtual Network**  
- Defines an **Azure Virtual Network (VNet)** named `container-dns-vnet`.  
- The VNet has an **address space** of `10.0.0.0/16`.  
- It contains two **subnets**:  
  1. **PrivateEndpointSubnet** (`10.0.1.0/24`) for private endpoints.  
  2. **ContainerInstanceSubnet** (`10.0.2.0/24`) for Azure Container Instances, with a **delegation** to `Microsoft.ContainerInstance/containerGroups`, allowing container instances to use the subnet.  

#### **Private DNS Zone**  
- Creates a **Private DNS Zone** for **Azure Storage file services** (`privatelink.file.core.windows.net`).  
- Links the **Virtual Network (VNet)** to the DNS zone using `virtualNetworkLink`, ensuring private name resolution within the VNet.  

#### **Managed Identity**  
- Defines a **User-Assigned Managed Identity** to provide secure access to Azure resources without storing credentials.  

This setup enables secure private networking and DNS resolution for containerized workloads using Azure services. 


## 3. Use an Existing Storage Account  




```bicep
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

```

 

#### **Storage Account**  
- Defines an **Azure Storage Account** with the name `storageAccountName`.  
- Uses the **Standard_LRS** SKU (locally redundant storage).  
- **StorageV2** kind supports **blobs, files, tables, and queues**.  
- **Public network access is disabled**, ensuring restricted access.  
- **Network ACLs**:  
  - **Default action:** `Deny` (blocks all traffic).  
  - **Bypass:** `AzureServices` (allows trusted Azure services to access it).  

#### **File Share**  
- Creates an **Azure File Share** inside the **Storage Account**.  
- Named using the format: `${storageAccountName}/default/${fileShareName}`.  
- **Depends on** the `storageAccount` resource, ensuring it is created first.  

This configuration enhances security by restricting public access while allowing Azure services to interact with the storage securely. 

## 4. Configure role assignement

```bicep
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


``` 
 

#### **Role Assignment**  

- **Defines an existing role** (`Microsoft.Authorization/roleDefinitions`) named `storageFileDataPrivilegedContributorReference`.  
  - This role provides **elevated access** to manage Azure **Storage File data**.  
  - The role definition exists at the **tenant** scope.  

- **Creates a Role Assignment** (`Microsoft.Authorization/roleAssignments`):  
  - Assigns the **Storage File Data Privileged Contributor** role to a **Managed Identity**.  
  - The `name` is a unique GUID generated using the role ID, managed identity ID, and storage account ID.  
  - The **scope** is set to the `storageAccount`, restricting the role’s permissions to that resource.  
  - The **principalId** references the managed identity’s `principalId`.  
  - The **roleDefinitionId** links to the defined role.  
  - The **principalType** is `ServicePrincipal`, indicating it applies to a service identity.  

This setup ensures **secure and controlled access** to manage Azure Storage File data using a managed identity. 

## 4. Configure private endpoint

```bicep

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

``` 

 

#### **Private Endpoint for Storage File**  
- **Creates a Private Endpoint** (`privateEndpointStorageFile`) for a **Storage Account**.  
- Uses the **Private Link Service** to securely connect the storage account to a **private network**.  
- The **connection**:  
  - Links to the **Storage Account** (`privateLinkServiceId: storageAccount.id`).  
  - Uses **group ID** `file` to specify the file storage service.  
- The **custom network interface (NIC)** is named `${storageAccount.name}-nic`.  
- The **subnet** used is `privateEndpointSubnet` within the Virtual Network.  

#### **Private DNS Zone Group**  
- **Creates a Private DNS Zone Group** (`privateEndpointStorageFilePrivateDnsZoneGroup`).  
- Ensures **private name resolution** for the **Storage Account's file service**.  
- Associates the **Private Endpoint** with the **Private DNS Zone** (`privateStorageFileDnsZone`).  
- Enables seamless **private access** to storage services without exposing them to the public internet.  

This setup enhances **security** and **network isolation**, ensuring that storage traffic remains **private** and protected.

## 5. Configure a Container Instance  

```bicep

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
  }
}

```
### Explanation of the Code

#### **Container Group Definition**
- **Resource Type & API Version:**  
  Uses the `Microsoft.ContainerInstance/containerGroups@2023-05-01` API to deploy an Azure Container Instance group.

- **Name and Location:**  
  The container group is named using the variable `containerGroupName` and deployed in the specified `location`.

- **Managed Identity:**  
  - Configured with a **User Assigned Managed Identity**.
  - The managed identity is referenced by its ID (`${managedIdentity.id}`), which allows the container group to authenticate to other Azure resources securely.

#### **Networking**
- **Subnet Association:**  
  The container group is deployed into a specific subnet. It references the subnet ID from the virtual network's `containerInstanceSubnet`, ensuring that network traffic remains within the defined VNet.

#### **Container Configuration**
- **Container Details:**  
  - The container is named using the variable `containerName` and is based on the image specified by `containerImage`.
  - **Resource Requests:**  
    The container requests 1 CPU and 1.5 GB of memory. 
  - **Port Exposure:**  
    It exposes TCP port 80, allowing network communication on this port.

- **Volume Mounts:**  
  - The container mounts a volume named `filesharevolume` at the path defined by `mountPath`.  
  - This setup enables the container to access shared file storage.

- **Custom Command:**  
  - The container runs a shell command using `/bin/sh -c` that:
    1. Navigates to the directory `/mnt/azscripts/azscriptinput`.
    2. Checks if a file named `hello.ps1` exists.
    3. If the file exists, it executes the PowerShell script using `pwsh`.
    4. If not, it outputs a message indicating the file is missing and instructs to upload it.
    5. Finally, it sleeps for 1800 seconds (30 minutes) using PowerShell, keeping the container running.

#### **Operating System**
- **OS Type:**  
  The container group is set to use Linux as its operating system.

#### **Volume Definition**
- **Azure File Share Volume:**  
  - A volume named `filesharevolume` is defined.
  - It uses the **Azure File Share** service, specifying:
    - **Share Name:** Provided by the variable `fileShareName`.
    - **Storage Account Details:** Uses `storageAccountName` and retrieves the storage account key via `storageAccount.listKeys().keys[0].value`.
  - The volume is not read-only, allowing write operations within the container.

---

This configuration deploys a containerized application in a secure, isolated network environment. The container is empowered with a managed identity for secure resource access, leverages an Azure File Share for persistent storage, and uses a custom command to conditionally execute a PowerShell script upon startup.

---

### 6. Bicep Code   

```bicep
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


```

---

### Deployment Commands  

```powershell
$templateFile = 'main.bicep' 
$resourceGroupName = 'RG-DEPLOYMENT-SCRIPT-PRIVATE-CUSTOM-DNS'
$resourceGroupLocation='westeurope'
$deploymentName = 'deployment-$resourceGroupName-$resourceGroupLocation'

# Create a resource group
az group create -l $resourceGroupLocation -n $resourceGroupName 

# Deploy the Bicep template
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $templateFile -DeploymentDebugLogLevel All  
```

## 7. Monitoring

You should upload the PowerShell file you want to run to the storage account file share, as shown below.


![fileshare](https://github.com/user-attachments/assets/44cad097-ab37-4450-a46c-4cbea1270a65)

When you restart the container, the PowerShell script should execute automatically, as demonstrated.

In this scenario, I am deploying the storage account and container instance at the same time, so I need to upload the PowerShell file and then restart the container.
However, if you already have a storage account with the PowerShell script in place, there is no need to restart the container.

![container logs](https://github.com/user-attachments/assets/efd52bf3-47a5-48ce-b9f7-9379adbab88e)

You can also open a shell (/bin/sh) inside the container  and run script manualy

![container run](https://github.com/user-attachments/assets/9911a953-3416-4a3c-89ac-99029b3370e7)


```powershell
$containerName='datasynchrocg'
$resourceGroupName = 'RG-DEPLOYMENT-SCRIPT-PRIVATE-CUSTOM-DNS'

az container logs --resource-group $resourceGroupName --name $containerName

az container attach --resource-group $resourceGroupName --name $containerName

az container show --resource-group $resourceGroupName --name $containerName

az container exec --resource-group $resourceGroupName --name $containerName --exec-command "/bin/sh"

cd /mnt/azscripts/azscriptinput
ls 
pwsh ./hello.ps1

```
### Brief Explanation

1. **Variable Initialization:**
   - Sets the container name to `datasynchrocg`.
   - Sets the resource group name to `RG-DEPLOYMENT-SCRIPT-PRIVATE-CUSTOM-DNS`.

2. **Viewing Container Information:**
   - **Retrieve Logs:** Uses `az container logs` to display the container's log output.
   - **Attach to Container:** Uses `az container attach` to connect interactively to the container's console.
   - **Show Details:** Uses `az container show` to display detailed information about the container instance.

3. **Interactive Shell and Script Execution:**
   - **Execute Shell Command:** Uses `az container exec` to open a shell (`/bin/sh`) inside the container.
   - **Navigate and List Files:** Once inside the container, changes directory to `/mnt/azscripts/azscriptinput` and lists the directory contents.
   - **Run Script:** Executes the PowerShell script `hello.ps1` using `pwsh` if it is present in that directory.

## 8. Github Repository

https://github.com/azurecorner/deployment-script-privately-over-a-private-endpoint-custum-dns
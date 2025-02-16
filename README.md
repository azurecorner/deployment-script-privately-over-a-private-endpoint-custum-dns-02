# Run Deployment Script Privately in Azure Over Private Endpoint and Custom DNS Server Using Bicep Part2

## 1. Overview

Azure Deployment Scripts allow you to run PowerShell or Azure CLI scripts during a Bicep deployment. This is useful for tasks like configuring resources, retrieving values, or executing custom logic.  
[Learn more about Deployment Scripts in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-script-bicep?tabs=CLI)

In my previous tutorial, I provided an introduction to Azure deployment scripts: Run Script in Azure Using Deployment Scripts and Bicep (<https://logcorner.com/run-script-in-azure-using-deployment-scripts-and-bicep/>)

The deployment script service requires both a Storage Account and an Azure Container Instance.

In a private environment, you can use an existing Storage Account with a private endpoint enabled. However, a deployment script requires a new Azure Container Instance and cannot use an existing one.

For more details on running a Bicep deployment script privately over a private endpoint, refer to this article: Run Bicep Deployment Script Privately (<https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-script-vnet-private-endpoint>).

In the article linked above, the Azure Container Instance resource is created automatically by the deployment script. But what happens if you use a custom DNS server? The limitation is that you cannot use a custom DNS server because the ACI is created automatically, and the only configurable option is the container group name.

In this tutorial, I will demonstrate how to use a custom DNS server to run a script in Azure Part2.

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

### 2.1 Virtual Network

```Bicep
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
```

The `dhcpOptions` block in the **Azure Virtual Network (VNet)** configuration specifies **custom DNS servers** for the network. It specifies the private resolver inbound ip address that network resources will use instead of Azure default DNS.

```Bicep

dhcpOptions: {
      dnsServers: [
       '10.0.3.70'
      ]
    }
```

Here I define a **subnet** resource inside a Virtual Network (**VNet**) and delegates it to **Azure DNS Private Resolver** allowing the subnet to be used for Azure Private DNS Resolution.

```Bicep
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

```

### 2.2 Private Resolver

This Bicep code defines an **Azure Private DNS Resolver** with an **Inbound Endpoint** inside a **Virtual Network (VNet)**.  
The **Private DNS Resolver** allows private DNS resolution within an **Azure environment** or from **on-premises networks**.

```Bicep
/*  ------------------------------------------ Private Resolver ------------------------------------------ */
resource privateResolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: 'privateResolver'
  location: location
  properties: {
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
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

```

#### **Private DNS Resolver Resource Definition**

- **Defines a Private DNS Resolver** named `privateResolver`.
- Uses the **resource type** `'Microsoft.Network/dnsResolvers'`.
- **`location`**: Specifies the **region** where the resolver is deployed.
- **`virtualNetwork.id`**: Associates the resolver with an **existing Virtual Network (VNet)**.

The **Private DNS Resolver** is used to **resolve DNS queries** for **private resources** within **Azure**.
It operates inside a **Virtual Network (VNet)**, enabling **private name resolution**.

#### **Inbound Endpoint Resource Definition**

- **Defines an Inbound Endpoint** named `inboundEndpoint`.
- Uses the **resource type** `'Microsoft.Network/dnsResolvers/inboundEndpoints'`.
- **`parent: privateResolver`**: This endpoint is **attached** to the `privateResolver` resource.

#### **IP Configurations**

- **`privateIpAddress: '10.0.3.70'`** → Assigns a **static private IP** for DNS resolution.
- **`privateIpAllocationMethod: 'Static'`** → Ensures the IP remains **fixed**.
- **`subnet.id`** → Places the endpoint in a **dedicated subnet** (`privateResolverInboundSubnet`).

The **Inbound Endpoint** allows **on-premises** or **cross-VNet resources** to send **DNS queries** for **private resolution**.
The **IP address** (`10.0.3.70`) is used by **clients** to resolve **private domains**.

### 2.3  Container Group

```Bicep
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

```

The `dnsConfig` block of the configuration for the  **Azure Container Group** specifies custom DNS server settings for the containers within the group.

#### **dnsConfig**

- Defines **DNS settings** for the **container group**.

#### **nameServers**

- Specifies the list of **DNS servers** the containers will use for **name resolution**.
- **`'10.0.3.70'`** is a **static IP of Private Resolver Inbound IP** address that will be used by the containers for **DNS queries**.

```Bicep
    dnsConfig: {
      nameServers: [
       '10.0.3.70'
      ]
  }
```

## 3  Deployment Commands  

```powershell
$templateFile = 'main.bicep' 
$resourceGroupName = 'RG-DEPLOYMENT-SCRIPT-PRIVATE-CUSTOM-DNS'
$resourceGroupLocation='westeurope'

$subscriptionId= (Get-AzContext).Subscription.id
az account set --subscription $subscriptionId


$deploymentName = 'deployment-$resourceGroupName-$resourceGroupLocation'

# Create the resource group
New-AzResourceGroup -Name $resourceGroupName -Location "westeurope"

# Deploy the Bicep template
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $templateFile -DeploymentDebugLogLevel All  
```

## 4. Monitoring

You should upload the PowerShell file you want to run to the storage account file share, as shown below.

![monitoring](https://github.com/user-attachments/assets/a119c792-8bc1-47ef-b371-ebc4efafd94f)

![nslookup 1](https://github.com/user-attachments/assets/c818aa73-473a-449e-90b7-aa1d241f99ab)

![nslookup 2](https://github.com/user-attachments/assets/6d61a39c-5c81-4594-9df3-ef7ecab545dd)

```powershell
$containerName='datasynchrocg'
$resourceGroupName = 'RG-DEPLOYMENT-SCRIPT-PRIVATE-CUSTOM-DNS'

az container exec --resource-group $resourceGroupName --name $containerName --exec-command "/bin/sh"

```

Install sudo and DNS Utilities

```bash

su -
apt-get update
apt-get install -y sudo
sudo apt-get update
sudo apt-get install -y dnsutils


Test DNS Resolution

```bash
nslookup datasynchrostore.file.core.windows.net

```

```bash
root@SandboxHost-638752067807257456:~# nslookup datasynchrostore.file.core.windows.net
Server:         10.0.3.70
Address:        10.0.3.70#53

Non-authoritative answer:
datasynchrostore.file.core.windows.net  canonical name = datasynchrostore.privatelink.file.core.windows.net.
Name:   datasynchrostore.privatelink.file.core.windows.net
Address: 10.0.1.4

root@SandboxHost-638752067807257456:~#

```

- Server: 10.0.3.70: The DNS server used for the lookup (Inbound Ip of Private Resolver).
- Address: 10.0.3.70#53: The IP address and port of the DNS server.
- Canonical Name: Resolves datasynchrostore.file.core.windows.net to datasynchrostore.privatelink.file.core.windows.net.
- IP Address: The resolved IP address is 10.0.1.4.


## 8. Github Repository

<https://github.com/azurecorner/deployment-script-privately-over-a-private-endpoint-custum-dns>

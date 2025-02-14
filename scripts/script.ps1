$projectName ='datasynchro' #Read-Host -Prompt "Enter the same project name that you used earlier"
$fileName = 'C:\Users\LEYE-GORA\source\repos\AZURE WARRIORS\deployment script privately over a private endpoint\dns\hello.ps1' #Read-Host -Prompt "Enter the deployment script file name with the path"

$resourceGroupName ='RG-DEPLOYMENT-SCRIPT-DNS' #"${projectName}rg"
$storageAccountName = 'datasynchrostore' #"${projectName}store"
$fileShareName = 'datasynchroshare' #"${projectName}share"

$context = (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName).Context
Set-AzStorageFileContent -Context $context -ShareName $fileShareName -Source $fileName -Force



cd /mnt/azscripts/azscriptinput

ls
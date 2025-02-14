$name = 'Gora LEYE'
$output = "Hello  $name"
Write-Host $output

$DeploymentScriptOutputs = @{}
$DeploymentScriptOutputs['greeting'] = $output
Write-Output $DeploymentScriptOutputs
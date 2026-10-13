param([string]$ResourceGroup = 'rg-saludos-e1-20261013')

$ErrorActionPreference = 'Stop'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'No se encontró Azure CLI.'
}

$exists = & az group exists -n $ResourceGroup
if ($LASTEXITCODE -ne 0 -or $exists -ne 'true') {
    throw "No existe el grupo $ResourceGroup en la suscripción activa."
}

Write-Host 'Subredes:'
& az network vnet subnet list -g $ResourceGroup --vnet-name vnet-saludos-e1 `
    --query '[].{nombre:name,prefijo:addressPrefix,delegacion:delegations[0].serviceName}' -o table

Write-Host 'VM e IP privadas:'
foreach ($nic in @('nic-saludos-frontend', 'nic-saludos-backend')) {
    & az network nic show -g $ResourceGroup -n $nic `
        --query '{nombre:name,ipPrivada:ipConfigurations[0].privateIPAddress,ipPublica:ipConfigurations[0].publicIPAddress.id}' -o jsonc
}

Write-Host 'PostgreSQL:'
& az postgres flexible-server list -g $ResourceGroup `
    --query '[].{nombre:name,host:fullyQualifiedDomainName,estado:state,accesoPublico:network.publicNetworkAccess}' -o table

Write-Host 'IP pública de Application Gateway:'
$gatewayIp = (& az network public-ip show -g $ResourceGroup -n pip-saludos-appgw --query ipAddress -o tsv).Trim()
Write-Host "http://$gatewayIp"

Write-Host 'Salud del backend en Application Gateway:'
& az network application-gateway show-backend-health -g $ResourceGroup -n agw-saludos-e1 `
    --query 'backendAddressPools[].backendHttpSettingsCollection[].servers[].{direccion:address,estado:health}' -o table

try {
    $response = Invoke-RestMethod -Uri "http://$gatewayIp/api/saludo" -TimeoutSec 15
    Write-Host 'Respuesta pública del flujo completo:'
    Write-Host ($response | ConvertTo-Json -Compress)
} catch {
    Write-Warning 'La aplicación aún no respondió por el gateway. Antes del primer CD esto es normal.'
}

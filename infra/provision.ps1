param(
    [string]$Location = 'eastus2',
    [string]$ResourceGroup = 'rg-saludos-e1-20261013',
    [string]$SshPublicKeyPath = "$HOME/.ssh/id_ed25519.pub",
    [string]$DbAdminUser = 'saludosadmin',
    [string]$FrontendVmSize = 'Standard_B2s',
    [string]$BackendVmSize = 'Standard_B1ms',
    [string]$DbSku = 'Standard_D2s_v3',
    [string]$DbTier = 'GeneralPurpose',
    [string]$DbZone = '2',
    [string]$DbPasswordFile = '',
    [switch]$CostReviewed,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if (-not $DbPasswordFile) {
    $DbPasswordFile = Join-Path (Split-Path $PSScriptRoot -Parent) '.secrets/db-admin-password.txt'
}

function Invoke-Az {
    param([string[]]$CliArgs)
    & az @CliArgs --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) {
        throw "Falló Azure CLI en: $($CliArgs[0]) $($CliArgs[1]). Revise el error anterior."
    }
}

function Test-AzResource {
    param([string[]]$CliArgs)
    $null = & az @CliArgs --query id -o tsv --only-show-errors 2>$null
    return $LASTEXITCODE -eq 0
}

function Ensure-AzResource {
    param([string[]]$ShowArgs, [string[]]$CreateArgs, [string]$Label)
    if (Test-AzResource -CliArgs $ShowArgs) {
        Write-Host "Ya existe: $Label"
    } else {
        Write-Host "Creando: $Label"
        Invoke-Az -CliArgs $CreateArgs
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Instale Azure CLI y ejecute az login antes de usar este script.'
}

$subscriptionId = (& az account show --query id -o tsv --only-show-errors).Trim()
if ($LASTEXITCODE -ne 0 -or -not $subscriptionId) {
    throw 'Azure CLI no tiene una suscripción activa. Ejecute az login y az account set.'
}

$hasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $hash = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$subscriptionId/$ResourceGroup"))
    $suffix = ([System.BitConverter]::ToString($hash)).Replace('-', '').Substring(0, 8).ToLowerInvariant()
} finally {
    $hasher.Dispose()
}

$vnet = 'vnet-saludos-e1'
$frontendNic = 'nic-saludos-frontend'
$backendNic = 'nic-saludos-backend'
$frontendVm = 'vm-saludos-frontend'
$backendVm = 'vm-saludos-backend'
$frontendNsg = 'nsg-saludos-frontend'
$backendNsg = 'nsg-saludos-backend'
$natPublicIp = 'pip-saludos-nat'
$gatewayPublicIp = 'pip-saludos-appgw'
$natGateway = 'nat-saludos-e1'
$gateway = 'agw-saludos-e1'
$dbServer = "pgsaludose1$suffix"
$privateDnsZone = 'saludos.private.postgres.database.azure.com'

Write-Host "Suscripción activa: $subscriptionId"
Write-Host "Región: $Location | Grupo: $ResourceGroup"
Write-Host "VM frontend: $FrontendVmSize | VM backend: $BackendVmSize | PostgreSQL: $DbSku ($DbTier)"
Write-Host "Servidor PostgreSQL previsto: $dbServer"
Write-Host 'Este laboratorio incluye recursos facturables: dos VM, discos, Application Gateway, NAT, IP públicas y PostgreSQL.'

if (-not $Apply) {
    Write-Host 'Solo vista previa. Revise precios y ejecute de nuevo con -CostReviewed -Apply para crear recursos.'
    return
}
if (-not $CostReviewed) {
    throw 'Antes de crear recursos, revise los precios de su región y agregue -CostReviewed.'
}
if (-not (Test-Path -LiteralPath $SshPublicKeyPath -PathType Leaf)) {
    throw "No se encontró la clave SSH pública: $SshPublicKeyPath"
}

$providerState = & az provider show --namespace Microsoft.Network --query registrationState -o tsv --only-show-errors
if ($providerState -ne 'Registered') {
    Write-Host 'Registrando Microsoft.Network...'
    Invoke-Az -CliArgs @('provider', 'register', '--namespace', 'Microsoft.Network')
    do {
        Start-Sleep -Seconds 10
        $providerState = & az provider show --namespace Microsoft.Network --query registrationState -o tsv --only-show-errors
    } until ($providerState -eq 'Registered')
}

Ensure-AzResource -Label $ResourceGroup `
    -ShowArgs @('group', 'show', '-n', $ResourceGroup) `
    -CreateArgs @('group', 'create', '-n', $ResourceGroup, '-l', $Location,
                  '--tags', 'proposito=entregable-devops-1')

Ensure-AzResource -Label $vnet `
    -ShowArgs @('network', 'vnet', 'show', '-g', $ResourceGroup, '-n', $vnet) `
    -CreateArgs @('network', 'vnet', 'create', '-g', $ResourceGroup, '-n', $vnet, '-l', $Location,
                  '--address-prefixes', '10.1.0.0/16', '--subnet-name', 'snet-appgw', '--subnet-prefixes', '10.1.0.0/24')

$subnets = @(
    @{ Name = 'snet-frontend'; Prefix = '10.1.1.0/24' },
    @{ Name = 'snet-backend'; Prefix = '10.1.2.0/24' },
    @{ Name = 'snet-postgres'; Prefix = '10.1.3.0/24' }
)
foreach ($subnet in $subnets) {
    $createArgs = @('network', 'vnet', 'subnet', 'create', '-g', $ResourceGroup, '--vnet-name', $vnet,
                    '-n', $subnet.Name, '--address-prefixes', $subnet.Prefix)
    if ($subnet.Name -eq 'snet-postgres') {
        $createArgs += @('--delegations', 'Microsoft.DBforPostgreSQL/flexibleServers')
    }
    Ensure-AzResource -Label $subnet.Name `
        -ShowArgs @('network', 'vnet', 'subnet', 'show', '-g', $ResourceGroup, '--vnet-name', $vnet, '-n', $subnet.Name) `
        -CreateArgs $createArgs
}

foreach ($nsg in @($frontendNsg, $backendNsg)) {
    Ensure-AzResource -Label $nsg `
        -ShowArgs @('network', 'nsg', 'show', '-g', $ResourceGroup, '-n', $nsg) `
        -CreateArgs @('network', 'nsg', 'create', '-g', $ResourceGroup, '-n', $nsg, '-l', $Location)
}

$nsgRules = @(
    @{ Nsg = $frontendNsg; Name = 'AllowGateway8080'; Priority = '100'; Source = '10.1.0.0/24'; Port = '8080'; Access = 'Allow' },
    @{ Nsg = $frontendNsg; Name = 'DenyOtherVnetInbound'; Priority = '200'; Source = 'VirtualNetwork'; Port = '*'; Access = 'Deny' },
    @{ Nsg = $backendNsg; Name = 'AllowFrontend5000'; Priority = '100'; Source = '10.1.1.0/24'; Port = '5000'; Access = 'Allow' },
    @{ Nsg = $backendNsg; Name = 'DenyOtherVnetInbound'; Priority = '200'; Source = 'VirtualNetwork'; Port = '*'; Access = 'Deny' }
)
foreach ($rule in $nsgRules) {
    Ensure-AzResource -Label "$($rule.Nsg)/$($rule.Name)" `
        -ShowArgs @('network', 'nsg', 'rule', 'show', '-g', $ResourceGroup, '--nsg-name', $rule.Nsg, '-n', $rule.Name) `
        -CreateArgs @('network', 'nsg', 'rule', 'create', '-g', $ResourceGroup, '--nsg-name', $rule.Nsg,
                      '-n', $rule.Name, '--priority', $rule.Priority, '--direction', 'Inbound',
                      '--source-address-prefixes', $rule.Source, '--source-port-ranges', '*',
                      '--destination-address-prefixes', '*', '--destination-port-ranges', $rule.Port,
                      '--protocol', '*', '--access', $rule.Access)
}

foreach ($pip in @($natPublicIp, $gatewayPublicIp)) {
    Ensure-AzResource -Label $pip `
        -ShowArgs @('network', 'public-ip', 'show', '-g', $ResourceGroup, '-n', $pip) `
        -CreateArgs @('network', 'public-ip', 'create', '-g', $ResourceGroup, '-n', $pip, '-l', $Location,
                      '--sku', 'Standard', '--allocation-method', 'Static')
}
Ensure-AzResource -Label $natGateway `
    -ShowArgs @('network', 'nat', 'gateway', 'show', '-g', $ResourceGroup, '-n', $natGateway) `
    -CreateArgs @('network', 'nat', 'gateway', 'create', '-g', $ResourceGroup, '-n', $natGateway,
                  '-l', $Location, '--public-ip-addresses', $natPublicIp, '--idle-timeout', '4')
foreach ($subnetName in @('snet-frontend', 'snet-backend')) {
    Invoke-Az -CliArgs @('network', 'vnet', 'subnet', 'update', '-g', $ResourceGroup,
                        '--vnet-name', $vnet, '-n', $subnetName, '--nat-gateway', $natGateway)
}

Ensure-AzResource -Label $privateDnsZone `
    -ShowArgs @('network', 'private-dns', 'zone', 'show', '-g', $ResourceGroup, '-n', $privateDnsZone) `
    -CreateArgs @('network', 'private-dns', 'zone', 'create', '-g', $ResourceGroup, '-n', $privateDnsZone)
Ensure-AzResource -Label 'link-saludos-vnet' `
    -ShowArgs @('network', 'private-dns', 'link', 'vnet', 'show', '-g', $ResourceGroup,
                '-z', $privateDnsZone, '-n', 'link-saludos-vnet') `
    -CreateArgs @('network', 'private-dns', 'link', 'vnet', 'create', '-g', $ResourceGroup,
                  '-z', $privateDnsZone, '-n', 'link-saludos-vnet', '-v', $vnet, '-e', 'false')

if (-not (Test-AzResource -CliArgs @('postgres', 'flexible-server', 'show', '-g', $ResourceGroup, '-n', $dbServer))) {
    if (Test-Path -LiteralPath $DbPasswordFile -PathType Leaf) {
        $plainPassword = (Get-Content -LiteralPath $DbPasswordFile -Raw).Trim()
    } else {
        $plainPassword = ([Convert]::ToBase64String(
            [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(30))).TrimEnd('=') + 'Aa1!'
        $secretDir = Split-Path -Parent $DbPasswordFile
        New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
        Set-Content -LiteralPath $DbPasswordFile -Value $plainPassword -NoNewline -Encoding utf8
    }
    try {
        Invoke-Az -CliArgs @('postgres', 'flexible-server', 'create', '-g', $ResourceGroup, '-n', $dbServer,
                            '-l', $Location, '--admin-user', $DbAdminUser, '--admin-password', $plainPassword,
                            '--vnet', $vnet, '--subnet', 'snet-postgres', '--private-dns-zone', $privateDnsZone,
                            '--sku-name', $DbSku, '--tier', $DbTier, '--storage-size', '32', '--version', '16',
                            '--zone', $DbZone)
    } finally {
        $plainPassword = $null
    }
} else {
    Write-Host "Ya existe: $dbServer"
}
Ensure-AzResource -Label 'base saludos' `
    -ShowArgs @('postgres', 'flexible-server', 'db', 'show', '-g', $ResourceGroup, '-s', $dbServer, '-d', 'saludos') `
    -CreateArgs @('postgres', 'flexible-server', 'db', 'create', '-g', $ResourceGroup, '-s', $dbServer, '-d', 'saludos')

Ensure-AzResource -Label $frontendNic `
    -ShowArgs @('network', 'nic', 'show', '-g', $ResourceGroup, '-n', $frontendNic) `
    -CreateArgs @('network', 'nic', 'create', '-g', $ResourceGroup, '-n', $frontendNic,
                  '--vnet-name', $vnet, '--subnet', 'snet-frontend', '--network-security-group', $frontendNsg)
Ensure-AzResource -Label $backendNic `
    -ShowArgs @('network', 'nic', 'show', '-g', $ResourceGroup, '-n', $backendNic) `
    -CreateArgs @('network', 'nic', 'create', '-g', $ResourceGroup, '-n', $backendNic,
                  '--vnet-name', $vnet, '--subnet', 'snet-backend', '--network-security-group', $backendNsg)

$cloudInit = Join-Path $PSScriptRoot 'cloud-init.yaml'
foreach ($vm in @(
    @{ Name = $frontendVm; Nic = $frontendNic; Size = $FrontendVmSize },
    @{ Name = $backendVm; Nic = $backendNic; Size = $BackendVmSize }
)) {
    Ensure-AzResource -Label $vm.Name `
        -ShowArgs @('vm', 'show', '-g', $ResourceGroup, '-n', $vm.Name) `
        -CreateArgs @('vm', 'create', '-g', $ResourceGroup, '-n', $vm.Name, '-l', $Location,
                      '--nics', $vm.Nic, '--image', 'Ubuntu2204', '--size', $vm.Size,
                      '--admin-username', 'azureuser', '--authentication-type', 'ssh',
                      '--ssh-key-values', $SshPublicKeyPath, '--custom-data', $cloudInit,
                      '--assign-identity', '[system]', '--storage-sku', 'Standard_LRS')
}

$frontendIp = (& az network nic show -g $ResourceGroup -n $frontendNic --query 'ipConfigurations[0].privateIPAddress' -o tsv --only-show-errors).Trim()
$backendIp = (& az network nic show -g $ResourceGroup -n $backendNic --query 'ipConfigurations[0].privateIPAddress' -o tsv --only-show-errors).Trim()

Ensure-AzResource -Label $gateway `
    -ShowArgs @('network', 'application-gateway', 'show', '-g', $ResourceGroup, '-n', $gateway) `
    -CreateArgs @('network', 'application-gateway', 'create', '-g', $ResourceGroup, '-n', $gateway,
                  '-l', $Location, '--vnet-name', $vnet, '--subnet', 'snet-appgw',
                  '--public-ip-address', $gatewayPublicIp, '--sku', 'Standard_v2', '--capacity', '1',
                  '--frontend-port', '80', '--http-settings-port', '8080',
                  '--http-settings-protocol', 'Http', '--servers', $frontendIp, '--priority', '100')

if (-not (Test-AzResource -CliArgs @('network', 'application-gateway', 'probe', 'show', '-g', $ResourceGroup,
                                     '--gateway-name', $gateway, '-n', 'probe-frontend'))) {
    Invoke-Az -CliArgs @('network', 'application-gateway', 'probe', 'create', '-g', $ResourceGroup,
                        '--gateway-name', $gateway, '-n', 'probe-frontend', '--protocol', 'Http',
                        '--host', '127.0.0.1', '--path', '/health', '--interval', '30',
                        '--timeout', '20', '--threshold', '3')
}
$httpSettings = (& az network application-gateway http-settings list -g $ResourceGroup --gateway-name $gateway --query '[0].name' -o tsv --only-show-errors).Trim()
Invoke-Az -CliArgs @('network', 'application-gateway', 'http-settings', 'update', '-g', $ResourceGroup,
                    '--gateway-name', $gateway, '-n', $httpSettings, '--probe', 'probe-frontend')

$dbHost = (& az postgres flexible-server show -g $ResourceGroup -n $dbServer --query fullyQualifiedDomainName -o tsv --only-show-errors).Trim()
$gatewayIp = (& az network public-ip show -g $ResourceGroup -n $gatewayPublicIp --query ipAddress -o tsv --only-show-errors).Trim()

Write-Host ''
Write-Host 'Aprovisionamiento terminado. Configure GitHub con estos valores (sin publicar la contraseña):'
Write-Host "DB_HOST=$dbHost"
Write-Host 'DB_NAME=saludos'
Write-Host "DB_USER=$DbAdminUser"
Write-Host "BACKEND_PRIVATE_IP=$backendIp"
Write-Host "FRONTEND_PRIVATE_IP=$frontendIp"
Write-Host "APP_URL=http://$gatewayIp"
Write-Host "DB_PASSWORD se guardó en $DbPasswordFile y debe configurarse como secreto de Production en GitHub."
Write-Host 'El gateway estará Unhealthy hasta desplegar el contenedor frontend.'

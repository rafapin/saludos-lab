param([int]$Port = 0)

$ErrorActionPreference = 'Stop'
if ($Port -eq 0) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $Port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$network = "saludos-test-$suffix"
$postgres = "saludos-postgres-$suffix"
$backend = "saludos-backend-$suffix"
$frontend = "saludos-frontend-$suffix"
$password = [guid]::NewGuid().ToString('N')

function Invoke-Docker {
    param([string[]]$DockerArgs)
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Falló Docker en: $($DockerArgs[0])"
    }
}

try {
    Invoke-Docker -DockerArgs @('build', '--target', 'test', '-t', 'saludos-backend:test', (Join-Path $root 'backend'))
    Invoke-Docker -DockerArgs @('build', '-t', 'saludos-backend:local', (Join-Path $root 'backend'))
    Invoke-Docker -DockerArgs @('build', '-t', 'saludos-frontend:local', (Join-Path $root 'frontend'))
    Invoke-Docker -DockerArgs @('network', 'create', $network)

    Invoke-Docker -DockerArgs @('run', '-d', '--name', $postgres, '--network', $network,
                                '--network-alias', 'db', '-e', 'POSTGRES_USER=saludos',
                                '-e', "POSTGRES_PASSWORD=$password", '-e', 'POSTGRES_DB=saludos',
                                'postgres:16-alpine')
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        & docker exec $postgres pg_isready -U saludos -d saludos 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'PostgreSQL local no inició a tiempo.' }

    Invoke-Docker -DockerArgs @('run', '-d', '--name', $backend, '--network', $network,
                                '--network-alias', 'backend', '-e', 'DB_HOST=db',
                                '-e', 'DB_NAME=saludos', '-e', 'DB_USER=saludos',
                                '-e', "DB_PASSWORD=$password", '-e', 'DB_SSLMODE=disable',
                                'saludos-backend:local')
    Invoke-Docker -DockerArgs @('run', '-d', '--name', $frontend, '--network', $network,
                                '-p', "127.0.0.1:${Port}:8080", '-e', 'BACKEND_HOST=backend',
                                '-e', 'BACKEND_PORT=5000', 'saludos-frontend:local')

    $result = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $result = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/saludo" -TimeoutSec 5
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $result -or $result.mensaje -ne 'Hola desde Azure' -or -not $result.database_time) {
        throw 'La prueba extremo a extremo no obtuvo el saludo y la hora de PostgreSQL.'
    }
    Write-Host 'Prueba completa: frontend -> backend -> PostgreSQL.'
    Write-Host ($result | ConvertTo-Json -Compress)
} finally {
    & docker rm -f $frontend $backend $postgres 2>$null | Out-Null
    & docker network rm $network 2>$null | Out-Null
}

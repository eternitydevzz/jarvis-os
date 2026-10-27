# Jarvis: arranca Docker y WAHA, y mantiene vivo el puente (lo reinicia si se cae).
# Lo lanza la tarea programada "Jarvis" al iniciar sesion (ver install-task.ps1).
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'start.log'
$ConsoleLog = Join-Path $LogDir 'bridge-console.log'
$Compose = Join-Path $Root 'waha\docker-compose.yml'
$Bridge = Join-Path $Root 'bridge\server.mjs'
$DockerDesktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$DockerWaitSeconds = 180
$RestartDelaySeconds = 5

New-Item -ItemType Directory -Force $LogDir | Out-Null

function Write-Log([string]$Message) {
    "$(Get-Date -Format s) $Message" | Add-Content -Path $LogFile -Encoding utf8
}

function Test-DockerEngine {
    docker info --format '{{.ServerVersion}}' *> $null
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-DockerEngine)) {
    Write-Log 'Docker apagado: arrancando Docker Desktop'
    Start-Process $DockerDesktop
    $deadline = (Get-Date).AddSeconds($DockerWaitSeconds)
    while (-not (Test-DockerEngine)) {
        if ((Get-Date) -gt $deadline) {
            Write-Log 'ERROR: Docker no respondio en 3 minutos'
            exit 1
        }
        Start-Sleep -Seconds 5
    }
}
Write-Log 'Docker listo'

docker compose -f $Compose up -d *>> $ConsoleLog
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: no pude levantar WAHA (codigo $LASTEXITCODE)"
    exit 1
}
Write-Log 'WAHA levantado'

$Node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $Node) {
    Write-Log 'ERROR: no encuentro node en el PATH'
    exit 1
}

while ($true) {
    Write-Log 'arrancando el puente'
    & $Node $Bridge *>> $ConsoleLog
    Write-Log "el puente se detuvo (codigo $LASTEXITCODE); reinicio en $RestartDelaySeconds s"
    Start-Sleep -Seconds $RestartDelaySeconds
}

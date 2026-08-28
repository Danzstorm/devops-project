#Requires -Version 5.1
<#
.SYNOPSIS
    Verifica que la maquina tenga todo lo necesario para trabajar en este repo.
.DESCRIPTION
    Primera pieza de automatizacion del proyecto. La idea es que nadie (incluido tu
    dentro de seis meses) pierda una hora depurando un error que en realidad era
    "no tenias kind instalado".
    Sale con codigo 1 si falta algo, para poder encadenarlo en un script o en CI.
.EXAMPLE
    .\scripts\preflight.ps1
#>

$tools = [ordered]@{
    'git'       = @{ Args = @('--version');                   Why = 'control de versiones' }
    'uv'        = @{ Args = @('--version');                   Why = 'gestor de Python: entornos, deps y ejecucion' }
    'docker'    = @{ Args = @('--version');                   Why = 'construir y correr contenedores' }
    'kubectl'   = @{ Args = @('version', '--client=true');    Why = 'hablar con el cluster' }
    'kind'      = @{ Args = @('--version');                   Why = 'cluster Kubernetes local sobre Docker' }
    'helm'      = @{ Args = @('version', '--short');          Why = 'instalar charts (ingress, monitoreo)' }
    'terraform' = @{ Args = @('version');                     Why = 'infraestructura como codigo' }
    'jq'        = @{ Args = @('--version');                   Why = 'parsear JSON en scripts' }
    'gh'        = @{ Args = @('--version');                   Why = 'operar GitHub desde la terminal' }
}

$missing = @()

Write-Host ""
Write-Host "  Preflight - entorno del proyecto devops" -ForegroundColor Cyan
Write-Host "  ---------------------------------------" -ForegroundColor Cyan

foreach ($name in $tools.Keys) {
    $spec = $tools[$name]
    $cmd = Get-Command $name -ErrorAction SilentlyContinue

    if (-not $cmd) {
        Write-Host ("  [FALTA] {0,-10} -> {1}" -f $name, $spec.Why) -ForegroundColor Red
        $missing += $name
        continue
    }

    # 2>&1 porque varias de estas herramientas escriben la version en stderr.
    $version = (& $name @($spec.Args) 2>&1 | Select-Object -First 1) -replace '\s+', ' '
    Write-Host ("  [ ok  ] {0,-10} {1}" -f $name, $version.Trim()) -ForegroundColor Green
}

# Tener el cliente de docker no sirve de nada si el daemon esta apagado:
# kind, compose y el build fallan igual. Se comprueba aparte.
Write-Host ""
if ($missing -notcontains 'docker') {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [ ok  ] daemon de Docker respondiendo" -ForegroundColor Green
    } else {
        Write-Host "  [FALTA] daemon de Docker no responde -> abre Docker Desktop y espera a que diga 'Engine running'" -ForegroundColor Red
        $missing += 'docker-daemon'
    }
}

Write-Host ""
if ($missing.Count -gt 0) {
    Write-Host "  Faltan $($missing.Count): $($missing -join ', ')" -ForegroundColor Red
    Write-Host "  Instala con:  winget install --id <ID> -e" -ForegroundColor Yellow
    Write-Host "  IDs: Kubernetes.kind  Hashicorp.Terraform  Helm.Helm  jqlang.jq  astral-sh.uv" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "  Todo listo." -ForegroundColor Green
Write-Host ""
exit 0

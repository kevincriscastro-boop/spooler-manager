<#
.SYNOPSIS
    Baixa a versao mais recente publicada na VPS e roda o instalador
    silencioso. Ponto unico dessa logica - usado tanto pelo vigia
    (WatchdogSpooler.ps1, nos horarios fixos) quanto pelo botao
    "Forcar Atualizacao" do Painel Admin (via SpoolerMonitor.ps1).
.DESCRIPTION
    Antes essa logica estava duplicada dentro do WatchdogSpooler.ps1 e do
    install.ps1, e um bug no caminho do instalador (esperava uma pasta
    "dist_spooler" dentro do zip que nao existe) ficou sem ser notado por
    dias porque a falha era silenciosa. Concentrar tudo aqui evita que as
    copias fiquem dessincronizadas de novo.
#>
param(
    # Quem chama normalmente passa a URL; sem ela, le do config.json ao lado.
    [string]$UpdateBaseUrl
)

if (-not $UpdateBaseUrl) {
    try {
        $UpdateBaseUrl = (Get-Content (Join-Path $PSScriptRoot "config.json") -Raw -ErrorAction Stop | ConvertFrom-Json).update_base_url
    } catch {}
}
if (-not $UpdateBaseUrl) { exit 1 }

try {
    $zipPath = "$env:TEMP\dist_spooler_update_$PID.zip"
    Invoke-WebRequest -Uri "$UpdateBaseUrl/dist_spooler.zip" -OutFile $zipPath -UseBasicParsing -TimeoutSec 120

    $extractPath = "$env:TEMP\dist_spooler_update_$PID"
    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $installerPath = Join-Path $extractPath "Instalar.bat"
    if (Test-Path $installerPath) {
        # Quem chama este script ja roda elevado (SYSTEM no vigia, ou o
        # proprio monitor elevado no caso do botao do painel), entao o
        # instalador nao pede UAC de novo neste contexto.
        Start-Process -FilePath $installerPath -ArgumentList "/silent" -Wait -WindowStyle Hidden
    }

    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    # Falha silenciosa (ex: VPS fora do ar) - quem chamou tenta de novo depois.
}

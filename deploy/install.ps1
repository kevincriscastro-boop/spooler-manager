<#
.SYNOPSIS
    Instalador de um comando so do Spooler Manager (Gerenciador do Spooler).
.DESCRIPTION
    Baixa a versao mais recente do servidor de atualizacao, extrai e roda o
    instalador oficial (pede elevacao/UAC normalmente). Uso, num PowerShell:

        irm http://seu-servidor:8990/install.ps1 | iex

    Este arquivo e um MODELO: o deploy (.github/workflows/deploy.yml) troca
    __UPDATE_BASE_URL__ pelo endereco real (secret UPDATE_BASE_URL) e publica
    o resultado no servidor, junto com o pacote.
#>
$ErrorActionPreference = "Stop"
# A barra de progresso do Invoke-WebRequest (PowerShell 5.1) deixa o download
# dezenas de vezes mais lento.
$ProgressPreference = "SilentlyContinue"
$baseUrl = "__UPDATE_BASE_URL__"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Spooler Manager - Instalador Rapido" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

Write-Host "[1/3] Baixando..." -ForegroundColor Yellow
$zipPath = "$env:TEMP\dist_spooler_download.zip"
Invoke-WebRequest -Uri "$baseUrl/dist_spooler.zip" -OutFile $zipPath -UseBasicParsing

Write-Host "[2/3] Extraindo..." -ForegroundColor Yellow
$extractPath = "$env:TEMP\dist_spooler_install"
if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

Write-Host "[3/3] Iniciando instalador...`n" -ForegroundColor Yellow
$installerPath = Join-Path $extractPath "Instalar.bat"

# Se este script ja estiver rodando elevado (ex: chamado de um processo que
# ja pediu UAC antes, ou como SYSTEM), NAO pede elevacao de novo - o Windows
# bloqueia silenciosamente pedidos de elevacao "duplos" (Acesso negado), sem
# nem mostrar uma segunda tela de UAC.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$jaElevado = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# NAO usar Start-Process -Wait: ele espera tambem os processos filhos, e o
# instalador abre o explorer.exe (icone da bandeja), que nao termina - a
# janela ficava parada no final mesmo com a instalacao concluida.
if ($jaElevado) {
    $proc = Start-Process -FilePath $installerPath -ArgumentList "/silent" -NoNewWindow -PassThru
} else {
    Write-Host "(aceite o UAC quando aparecer)" -ForegroundColor Yellow
    $proc = Start-Process -FilePath $installerPath -ArgumentList "/silent" -Verb RunAs -PassThru
}
if (-not $proc.WaitForExit(10 * 60 * 1000)) {
    Write-Host "`nO instalador ainda nao terminou depois de 10 minutos." -ForegroundColor Red
} else {
    Write-Host "`nConcluido! Painel: http://127.0.0.1:8989" -ForegroundColor Green
}

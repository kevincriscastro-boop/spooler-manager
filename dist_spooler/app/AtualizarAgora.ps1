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

    Cada passo fica registrado em update.log (e a saida completa do
    instalador em install-output.log), na pasta do app - legivel pelo
    painel via /api/update-log. Atualizacao que falha nao pode mais ser
    silenciosa.
#>
param(
    # Quem chama normalmente passa a URL; sem ela, le do config.json ao lado.
    [string]$UpdateBaseUrl,
    [string]$Origem = "manual"
)

# A barra de progresso do Invoke-WebRequest no PowerShell 5.1 deixa o download
# dezenas de vezes mais lento (mesmo com a janela escondida).
$ProgressPreference = "SilentlyContinue"

$logFile = Join-Path $PSScriptRoot "update.log"
function Write-UpdateLog([string]$Mensagem) {
    try {
        Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Origem] $Mensagem" -Encoding UTF8
        # Mantem o arquivo pequeno: so as ultimas 500 linhas.
        $linhas = Get-Content $logFile -ErrorAction Stop
        if ($linhas.Count -gt 600) { $linhas | Select-Object -Last 500 | Set-Content $logFile -Encoding UTF8 }
    } catch {}
}

if (-not $UpdateBaseUrl) {
    try {
        $UpdateBaseUrl = (Get-Content (Join-Path $PSScriptRoot "config.json") -Raw -ErrorAction Stop | ConvertFrom-Json).update_base_url
    } catch {}
}
if (-not $UpdateBaseUrl) {
    Write-UpdateLog "ERRO: sem endereco do servidor (config.json ausente ou sem update_base_url)"
    exit 1
}

$versaoAntes = try { (Get-Content (Join-Path $PSScriptRoot "VERSION") -Raw).Trim() } catch { "?" }
Write-UpdateLog "Inicio (versao instalada: $versaoAntes, usuario: $env:USERNAME)"

try {
    $zipPath = "$env:TEMP\dist_spooler_update_$PID.zip"
    Invoke-WebRequest -Uri "$UpdateBaseUrl/dist_spooler.zip" -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
    Write-UpdateLog "Download ok ($([Math]::Round((Get-Item $zipPath).Length / 1KB)) KB)"

    $extractPath = "$env:TEMP\dist_spooler_update_$PID"
    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $installerPath = Join-Path $extractPath "Instalar.bat"
    if (-not (Test-Path $installerPath)) {
        Write-UpdateLog "ERRO: Instalar.bat nao encontrado dentro do zip"
    } else {
        $versaoNova = try { (Get-Content (Join-Path $extractPath "VERSION") -Raw).Trim() } catch { "?" }
        Write-UpdateLog "Rodando instalador da versao $versaoNova"

        # Quem chama este script ja roda elevado (SYSTEM no vigia, ou o
        # proprio monitor elevado no caso do botao do painel), entao o
        # instalador nao pede UAC de novo neste contexto.
        #
        # NAO usar Start-Process -Wait: no PowerShell 5.1 ele espera tambem
        # todos os processos filhos, e o instalador abre o explorer.exe (icone
        # da bandeja), que pode nunca terminar - a atualizacao ficava presa
        # para sempre. WaitForExit espera so o proprio instalador, com limite.
        $saidaInstalador = Join-Path $PSScriptRoot "install-output.log"
        $proc = Start-Process -FilePath "cmd.exe" -WindowStyle Hidden -PassThru `
            -ArgumentList "/c `"`"$installerPath`" /silent > `"$saidaInstalador`" 2>&1`""
        if ($proc.WaitForExit(10 * 60 * 1000)) {
            $versaoDepois = try { (Get-Content (Join-Path $PSScriptRoot "VERSION") -Raw).Trim() } catch { "?" }
            $resultado = if ($versaoDepois -eq $versaoNova) { "OK" } else { "ERRO: versao instalada nao mudou" }
            Write-UpdateLog "Instalador terminou (codigo $($proc.ExitCode)) - versao agora: $versaoDepois - $resultado"
        } else {
            Write-UpdateLog "ERRO: instalador nao terminou em 10 minutos (ver install-output.log)"
        }
    }

    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    # Quem chamou tenta de novo depois (ex: VPS fora do ar) - mas fica registrado.
    Write-UpdateLog "ERRO: $($_.Exception.Message)"
}

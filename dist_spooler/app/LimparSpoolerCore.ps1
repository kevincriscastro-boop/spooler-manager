<#
.SYNOPSIS
    Módulo central de reinício do Spooler, expurgo da fila e atualização de métricas.
#>
param(
    [switch]$IsAutomatic,
    [string]$Reason = "Execução manual",
    [string]$AppDir = ""
)

# 1. Garante elevação de Administrador
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($IsAutomatic) { $argList += " -IsAutomatic" }
        if ($Reason) { $argList += " -Reason `"$Reason`"" }
        if ($AppDir) { $argList += " -AppDir `"$AppDir`"" }
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
        exit
    } catch {
        Write-Host "`n[ERRO] Requer privilégios de Administrador!" -ForegroundColor Red
        exit
    }
}

# Determina diretório de dados
if (-not $AppDir -or -not (Test-Path $AppDir)) {
    if (Test-Path "C:\ProgramData\GerenciadorSpooler\data.json") {
        $AppDir = "C:\ProgramData\GerenciadorSpooler"
    } else {
        $AppDir = $PSScriptRoot
    }
}
$dataFile = Join-Path $AppDir "data.json"

Clear-Host
$tipoExecucao = if ($IsAutomatic) { "AUTOMÁTICO (Fila travada > 5 min)" } else { "MANUAL (Forçado pelo Usuário)" }

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "       REINICIAR SPOOLER E LIMPAR FILA DE IMPRESSÃO            " -ForegroundColor Cyan
Write-Host "       Modo: $tipoExecucao" -ForegroundColor Yellow
Write-Host "================================================================`n" -ForegroundColor Cyan

# Função para contar impressões ativas
function Get-FilaImpressaoDetalhada {
    $total = 0
    $nomesImpressoras = @()
    try {
        $printers = Get-Printer -ErrorAction SilentlyContinue
        foreach ($p in $printers) {
            $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
            if ($jobs -and $jobs.Count -gt 0) {
                $total += $jobs.Count
                $nomesImpressoras += $p.Name
            }
        }
    } catch {}

    $spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
    $arquivosSpl = 0
    if (Test-Path $spoolPath) {
        $arquivos = Get-ChildItem -Path $spoolPath -Filter "*.spl" -Force -ErrorAction SilentlyContinue
        if ($arquivos) { $arquivosSpl = $arquivos.Count }
    }

    $finalCount = [Math]::Max($total, $arquivosSpl)
    $printersStr = if ($nomesImpressoras.Count -gt 0) { ($nomesImpressoras | Select-Object -Unique) -join ", " } else { "Geral" }

    return [PSCustomObject]@{
        Count = $finalCount
        Printers = $printersStr
    }
}

# 2. Contagem ANTES
Write-Host "[1/5] Verificando impressões ativas na fila..." -ForegroundColor Yellow
$dadosAntes = Get-FilaImpressaoDetalhada
$impressoesAntes = $dadosAntes.Count
$corAntes = if ($impressoesAntes -gt 0) { "Magenta" } else { "Gray" }
Write-Host "      -> Foram detectadas $impressoesAntes impressão(ões) na fila (Impressora: $($dadosAntes.Printers))." -ForegroundColor $corAntes

# 3. Parar o serviço Spooler
Write-Host "`n[2/5] Parando o serviço Spooler de Impressão..." -ForegroundColor Yellow
try {
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    Write-Host "      -> Serviço Spooler parado com sucesso." -ForegroundColor Green
} catch {
    Write-Host "      -> Forçando encerramento do processo spoolsv.exe..." -ForegroundColor DarkYellow
    Stop-Process -Name spoolsv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# 4. Limpar arquivos da pasta PRINTERS
Write-Host "`n[3/5] Limpando arquivos presos na fila de impressão..." -ForegroundColor Yellow
$spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
$removidos = 0
if (Test-Path $spoolDir) {
    $arquivos = Get-ChildItem -Path $spoolDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($arquivos) {
        $removidos = $arquivos.Count
        $arquivos | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Host "      -> $removidos arquivo(s) removido(s) da pasta de spool." -ForegroundColor Green
    } else {
        Write-Host "      -> Pasta de spool já se encontrava vazia." -ForegroundColor DarkGray
    }
} else {
    Write-Host "      -> Pasta $spoolDir não encontrada." -ForegroundColor Red
}

# 5. Iniciar o serviço Spooler
Write-Host "`n[4/5] Reiniciando o serviço Spooler de Impressão..." -ForegroundColor Yellow
try {
    Start-Service -Name Spooler -ErrorAction Stop
    Start-Sleep -Seconds 1
    Write-Host "      -> Serviço Spooler iniciado com sucesso." -ForegroundColor Green
} catch {
    Write-Host "      -> Erro ao iniciar serviço Spooler: $_" -ForegroundColor Red
}

# 6. Contagem DEPOIS
Write-Host "`n[5/5] Validando status pós-limpeza..." -ForegroundColor Yellow
$spoolerStatus = (Get-Service -Name Spooler).Status
$dadosDepois = Get-FilaImpressaoDetalhada
$impressoesDepois = $dadosDepois.Count
$corStatus = if ($spoolerStatus -eq 'Running') { "Green" } else { "Red" }
Write-Host "      -> Status do Spooler: $spoolerStatus" -ForegroundColor $corStatus
Write-Host "      -> Impressões restantes na fila: $impressoesDepois" -ForegroundColor Green

# 7. Atualização do data.json
$totalLimpas = [Math]::Max(0, ($impressoesAntes - $impressoesDepois))
if ($totalLimpas -eq 0 -and $removidos -gt 0) {
    $totalLimpas = [Math]::Ceiling($removidos / 2)
}

if (Test-Path $dataFile) {
    try {
        $jsonRaw = Get-Content -Path $dataFile -Raw -Encoding UTF8
        $dataObj = $jsonRaw | ConvertFrom-Json
        
        if ($IsAutomatic) {
            $dataObj.stats.restarts_auto++
        } else {
            $dataObj.stats.restarts_manual++
        }
        $dataObj.stats.total_prints_cleaned += $totalLimpas

        $novoHistorico = [PSCustomObject]@{
            id = (Get-Date).ToString("yyyyMMddHHmmss")
            timestamp = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")
            type = if ($IsAutomatic) { "Automático" } else { "Manual" }
            reason = $Reason
            printers = $dadosAntes.Printers
            jobs_before = $impressoesAntes
            jobs_after = $impressoesDepois
            cleaned = $totalLimpas
        }

        $histList = @($novoHistorico)
        if ($dataObj.history) {
            $histList += @($dataObj.history | Select-Object -First 49)
        }
        $dataObj.history = $histList

        $dataObj | ConvertTo-Json -Depth 10 | Set-Content -Path $dataFile -Encoding UTF8
        Write-Host "`n[MÉTRICAS] Estatísticas atualizadas com sucesso em data.json!" -ForegroundColor Cyan
    } catch {
        Write-Host "`n[AVISO] Falha ao atualizar data.json: $_" -ForegroundColor DarkYellow
    }
}

# 8. Notificação no Windows (Toast + Tray)
$tituloNotif = if ($IsAutomatic) { "Spooler: Reinício Automático" } else { "Spooler: Reinício Manual" }
$msgNotif = "Limpeza concluída!`nAntes: $impressoesAntes | Depois: $impressoesDepois`nMotivo: $Reason"

try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $textNodes = $template.GetElementsByTagName("text")
    $textNodes.Item(0).AppendChild($template.CreateTextNode($tituloNotif)) | Out-Null
    $textNodes.Item(1).AppendChild($template.CreateTextNode("Antes: $impressoesAntes | Depois: $impressoesDepois na fila. $Reason")) | Out-Null
    $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe")
    $notifier.Show($toast)
} catch {}

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = $tituloNotif
    $notify.BalloonTipText = $msgNotif
    $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $notify.Visible = $true
    $notify.ShowBalloonTip(4000)
    Start-Sleep -Milliseconds 500
    $notify.Dispose()
} catch {}

Write-Host "`n================================================================" -ForegroundColor Green
Write-Host " [SUCESSO] Operação finalizada e notificação enviada!" -ForegroundColor Green
Write-Host " Impressões antes: $impressoesAntes | Impressões agora: $impressoesDepois" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Green

Write-Host "`nEsta janela fechará em 5 segundos (ou pressione qualquer tecla)..." -ForegroundColor DarkGray
$t = 5
while ($t -gt 0) {
    if ([Console]::KeyAvailable) {
        [Console]::ReadKey($true) | Out-Null
        break
    }
    Start-Sleep -Seconds 1
    $t--
}

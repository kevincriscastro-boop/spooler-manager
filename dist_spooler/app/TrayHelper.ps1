<#
.SYNOPSIS
    Ícone da bandeja do sistema para o Gerenciador do Spooler.
.DESCRIPTION
    Roda SEM privilégio de Administrador (propositalmente) e é iniciado pela pasta
    "Inicializar" do Windows - não pelo Agendador de Tarefas.

    Motivo: processos disparados pelo Agendador de Tarefas não conseguem exibir
    ícone na bandeja de notificações nesta máquina (limitação do Windows), mesmo
    quando elevados. Um atalho na pasta Inicializar, por outro lado, é iniciado
    pelo próprio Explorer e funciona normalmente.

    Este script não mexe no Spooler diretamente - ele só:
      - Mostra o status (consultando a API pública /api/health do monitor real);
      - Abre o Painel Admin no navegador;
      - Aciona a limpeza manual (que pede elevação via UAC na hora, só quando usada).

    OBS (17/09/2026): este script ja teve uma logica de "perguntar antes de
    atualizar", mas foi removida - o icone nao e confiavel em varias maquinas
    de producao (algumas parecem nao ter monitor fisico conectado, o que
    trava o loop de mensagens do WinForms). A atualizacao automatica agora
    e 100% responsabilidade do WatchdogSpooler.ps1 (roda como SYSTEM, sem
    depender de tela nenhuma), em horarios fixos (11h e 15h).
#>
param(
    [string]$AppDir = ""
)

if (-not $AppDir -or -not (Test-Path $AppDir)) {
    if (Test-Path "C:\ProgramData\GerenciadorSpooler\data.json") {
        $AppDir = "C:\ProgramData\GerenciadorSpooler"
    } else {
        $AppDir = $PSScriptRoot
    }
}

$coreScript = Join-Path $AppDir "LimparSpoolerCore.ps1"
$port = 8989
$baseUrl = "http://127.0.0.1:$port"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Evita rodar duas instâncias ao mesmo tempo
$mutex = New-Object System.Threading.Mutex($false, "Global\GerenciadorSpoolerTrayHelper")
if (-not $mutex.WaitOne(0, $false)) {
    exit 0
}

$customIconPath = Join-Path $AppDir "app-icon.ico"
$appIcon = if (Test-Path $customIconPath) { New-Object System.Drawing.Icon($customIconPath) } else { [System.Drawing.SystemIcons]::Printer }

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $appIcon
$notifyIcon.Text = "Gerenciador de Spooler - verificando..."
$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuAbrir = $trayMenu.Items.Add("Abrir Painel Admin")
$menuForcar = $trayMenu.Items.Add("Forçar Limpeza Agora")
$trayMenu.Items.Add("-") | Out-Null
$menuSair = $trayMenu.Items.Add("Sair")
$notifyIcon.ContextMenuStrip = $trayMenu

$global:exitRequested = $false

$menuAbrir.add_Click({
    Start-Process "$baseUrl/"
})
$menuForcar.add_Click({
    # Pede elevação (UAC) só neste momento, de forma pontual - não fica rodando elevado o tempo todo.
    try {
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$coreScript`" -Reason `"Disparado pelo ícone da bandeja`" -AppDir `"$AppDir`""
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível iniciar a limpeza: $_", "Gerenciador de Spooler") | Out-Null
    }
})
$menuSair.add_Click({
    $global:exitRequested = $true
})
$notifyIcon.add_DoubleClick({
    Start-Process "$baseUrl/"
})

function Update-TrayStatus {
    try {
        $resp = Invoke-RestMethod -Uri "$baseUrl/api/health" -TimeoutSec 3 -ErrorAction Stop
        $texto = "Gerenciador de Spooler - $($resp.spooler_status)`nFila atual: $($resp.current_queue) impressão(ões)"
        $notifyIcon.Icon = $appIcon
    } catch {
        $texto = "Gerenciador de Spooler`nMonitor não está respondendo"
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
    }
    if ($texto.Length -gt 127) { $texto = $texto.Substring(0, 127) }
    $notifyIcon.Text = $texto
}

Update-TrayStatus
$notifyIcon.ShowBalloonTip(3000, "Gerenciador de Spooler", "Ícone de status ativo.", [System.Windows.Forms.ToolTipIcon]::Info)

$nextStatusCheck = (Get-Date).AddSeconds(15)
while (-not $global:exitRequested) {
    [System.Windows.Forms.Application]::DoEvents()

    if ((Get-Date) -ge $nextStatusCheck) {
        Update-TrayStatus
        $nextStatusCheck = (Get-Date).AddSeconds(15)
    }

    Start-Sleep -Milliseconds 200
}

$notifyIcon.Visible = $false
$notifyIcon.Dispose()
$mutex.ReleaseMutex()

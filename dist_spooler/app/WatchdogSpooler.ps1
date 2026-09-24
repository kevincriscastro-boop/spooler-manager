<#
.SYNOPSIS
    Vigia do Gerenciador do Spooler - roda a cada 5 minutos como SYSTEM
    (independente de login de usuario). Religa o monitor se ele nao estiver
    respondendo, e aplica atualizacoes automaticas em horarios fixos.
.DESCRIPTION
    O monitor principal (SpoolerMonitor.ps1) roda via tarefa "ao fazer logon",
    e por limitacoes do Windows Task Scheduler, esse gatilho as vezes nao
    dispara de forma confiavel apos reinicializacoes/logoffs. Este vigia
    e a rede de seguranca: nao mexe em nada da experiencia visual do
    monitor, so garante que ele volte a subir sozinho quando cair.

    Tambem verifica se ha uma versao nova publicada na VPS e aplica
    automaticamente, sem perguntar nada, nos horarios fixos das 11h e 15h
    (o instalador preserva senha, historico e maquinas cadastradas na Frota
    de cada instalacao). Fora desses horarios, so aguarda - nao interrompe
    nada durante o expediente.

    Excecao (catch-up): se a maquina ficar desligada/sem rede durante as
    duas janelas de um dia, ela nao fica presa esperando o dia seguinte -
    assim que o vigia rodar de novo depois das 15h05 daquele mesmo dia
    (ex: ao ligar o computador mais tarde), ele verifica e aplica a
    atualizacao pendente uma unica vez. Isso e controlado pelo arquivo
    LastUpdateCheck.txt (guarda a data do ultimo dia em que a verificacao
    realmente rodou).

    OBS: a versao anterior tinha um fluxo de "perguntar antes de atualizar"
    via TrayHelper.ps1, mas foi removido em 17/09/2026 porque o icone da
    bandeja nao e confiavel em varias maquinas de producao (algumas parecem
    nao ter monitor fisico conectado, o que trava o loop de mensagens do
    WinForms). Atualizacao automatica sem depender de tela nenhuma e mais
    robusto pra essas maquinas.
#>
$AppDir = "C:\ProgramData\GerenciadorSpooler"

# Endereco do servidor de atualizacao vem do config.json (ver SpoolerMonitor.ps1).
$updateBaseUrl = $null
try {
    $updateBaseUrl = (Get-Content (Join-Path $AppDir "config.json") -Raw -ErrorAction Stop | ConvertFrom-Json).update_base_url
} catch {}

# 1. Religa o monitor se nao estiver respondendo
try {
    Invoke-RestMethod -Uri "http://127.0.0.1:8989/api/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null
} catch {
    schtasks /run /tn "GerenciadorSpoolerMonitor" | Out-Null
}

# 2. Nos horarios fixos (11h e 15h), verifica e aplica atualizacao automatica
#    direto, sem perguntar nada - nao depende de nenhuma tela/icone.
try {
    $now = Get-Date
    $hoje = $now.ToString("yyyy-MM-dd")
    $lastCheckFile = Join-Path $AppDir "LastUpdateCheck.txt"
    $ultimoDiaChecado = if (Test-Path $lastCheckFile) { (Get-Content $lastCheckFile -Raw -ErrorAction Stop).Trim() } else { "" }

    $isForcedWindow = (($now.Hour -eq 11) -or ($now.Hour -eq 15)) -and ($now.Minute -lt 5)

    # Catch-up: se a maquina ja passou das 15h05 de hoje e ainda nao rodou
    # nenhuma verificacao hoje (ex: ficou desligada durante as duas janelas),
    # verifica assim que o vigia rodar de novo - sem esperar o dia seguinte.
    $passouDasDuasJanelasHoje = ($now.Hour -gt 15) -or ($now.Hour -eq 15 -and $now.Minute -ge 5)
    $isCatchUp = $passouDasDuasJanelasHoje -and ($ultimoDiaChecado -ne $hoje)

    if (($isForcedWindow -or $isCatchUp) -and $updateBaseUrl) {
        $localVersionFile = Join-Path $AppDir "VERSION"
        $localVersion = if (Test-Path $localVersionFile) { (Get-Content $localVersionFile -Raw -ErrorAction Stop).Trim() } else { "" }

        # O arquivo VERSION nao tem extensao, entao o servidor pode devolver o
        # conteudo como bytes (application/octet-stream) em vez de texto.
        $remoteRaw = (Invoke-WebRequest -Uri "$updateBaseUrl/VERSION" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop).Content
        if ($remoteRaw -is [byte[]]) {
            $remoteVersion = [System.Text.Encoding]::UTF8.GetString($remoteRaw).Trim()
        } else {
            $remoteVersion = $remoteRaw.ToString().Trim()
        }

        # So marca o dia como "checado" depois de conseguir falar com a VPS -
        # se ela estiver fora do ar, a excecao abaixo impede essa linha e o
        # vigia tenta de novo no proximo ciclo (nao perde o catch-up do dia).
        Set-Content -Path $lastCheckFile -Value $hoje -Encoding UTF8 -Force

        if ($remoteVersion -and $remoteVersion -ne $localVersion) {
            $updaterScript = Join-Path $AppDir "AtualizarAgora.ps1"
            if (Test-Path $updaterScript) {
                & $updaterScript -UpdateBaseUrl $updateBaseUrl
            }
        }
    }
} catch {
    # Falha silenciosa (ex: VPS fora do ar) - tenta de novo no proximo ciclo.
}

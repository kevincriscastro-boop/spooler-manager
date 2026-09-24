<#
.SYNOPSIS
    Serviço em segundo plano do Gerenciador do Spooler.
    - Monitora a fila de impressão a cada 30 segundos;
    - Reinicia automaticamente se detectar impressões travadas há mais de 5 minutos;
    - Fornece a API local e hospeda o Painel Administrativo em http://127.0.0.1:8989/.
#>
param(
    [string]$AppDir = ""
)

# 1. Verificacao de Privilegios de Administrador
# Quando instalado via schtasks /rl HIGHEST, ja roda como Administrador.
# Se iniciado manualmente sem elevacao, exibe aviso e sai.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`n[AVISO] Este monitor precisa ser executado como Administrador." -ForegroundColor Yellow
    Write-Host "        Use o instalador (Instalar.bat) para configurar corretamente.`n" -ForegroundColor Yellow
    exit 0
}

# 2. Definição do Diretório Base
if (-not $AppDir -or -not (Test-Path $AppDir)) {
    if (Test-Path "C:\ProgramData\GerenciadorSpooler\data.json") {
        $AppDir = "C:\ProgramData\GerenciadorSpooler"
    } else {
        $AppDir = $PSScriptRoot
    }
}

$dataFile = Join-Path $AppDir "data.json"
$dashFile = Join-Path $AppDir "dashboard.html"
$coreScript = Join-Path $AppDir "LimparSpoolerCore.ps1"
$versionFile = Join-Path $AppDir "VERSION"

# Endereco do servidor de atualizacao vem do config.json (gerado pelo deploy,
# fora do Git) - assim o codigo nao carrega o IP de nenhum ambiente real.
# Sem ele, o app funciona normal, so nao verifica/aplica atualizacoes.
$updateBaseUrl = $null
try {
    $updateBaseUrl = (Get-Content (Join-Path $AppDir "config.json") -Raw -ErrorAction Stop | ConvertFrom-Json).update_base_url
} catch {}
if (-not $updateBaseUrl) {
    Write-Host "[AVISO] config.json ausente ou sem update_base_url - atualizacao automatica desativada." -ForegroundColor Yellow
}

# Sessões ativas em memória
$global:activeTokens = @{}
$global:lastAutoRestart = [DateTime]::MinValue

# 3. Inicialização do Servidor HTTP (aceita conexões da rede local, não só deste PC,
#    para permitir o Painel de Frota gerenciar varias maquinas remotamente).
$port = 8989
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$($port)/")

try {
    $listener.Start()
    Write-Host "[HTTP] Servidor iniciado em http://+:$($port)/ (acessivel pela rede local)" -ForegroundColor Green
} catch {
    Write-Host "[ERRO] Não foi possível iniciar o HttpListener na porta $($port): $_" -ForegroundColor Red
    exit 1
}

# Funções Auxiliares

# Detecta o ID do AnyDesk instalado nesta máquina (se houver), para permitir
# acesso remoto rápido pelo Painel de Frota sem precisar salvar nada nos
# favoritos do AnyDesk (evita acionar a detecção de uso comercial/anúncios
# da versão gratuita).
$global:cachedAnyDeskId = $null
$global:anyDeskIdCheckedAt = [DateTime]::MinValue
function Get-AnyDeskId {
    # Cache de 5 minutos - o ID nao muda, nao precisa consultar toda hora.
    # Le direto do arquivo de configuracao (ad.anynet.id=NNNNNNNNNN dentro de
    # system.conf) em vez de tentar capturar a saida do AnyDesk.exe --get-id,
    # que e um app grafico e nao imprime de forma confiavel via stdout redirecionado.
    if ($global:cachedAnyDeskId -and ((Get-Date) - $global:anyDeskIdCheckedAt).TotalMinutes -lt 5) {
        return $global:cachedAnyDeskId
    }
    $global:anyDeskIdCheckedAt = Get-Date
    $confPaths = @(
        "C:\ProgramData\AnyDesk\system.conf",
        "$env:APPDATA\AnyDesk\system.conf"
    )
    foreach ($confPath in $confPaths) {
        if (Test-Path $confPath) {
            try {
                $linha = Get-Content -Path $confPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '^ad\.anynet\.id=(\d+)$' } | Select-Object -First 1
                if ($linha -match '^ad\.anynet\.id=(\d+)$') {
                    $global:cachedAnyDeskId = $matches[1]
                    return $global:cachedAnyDeskId
                }
            } catch {}
        }
    }
    $global:cachedAnyDeskId = $null
    return $null
}

# Especificacoes de hardware/SO (fabricante, modelo, numero de serie, versao
# do Windows) - usado na tela inicial publica ("Este Computador"). Cache de
# 1 hora porque essa informacao praticamente nunca muda durante a sessao.
$global:cachedMachineSpecs = $null
$global:machineSpecsCheckedAt = [DateTime]::MinValue
function Get-MachineSpecs {
    if ($global:cachedMachineSpecs -and ((Get-Date) - $global:machineSpecsCheckedAt).TotalMinutes -lt 60) {
        return $global:cachedMachineSpecs
    }
    $global:machineSpecsCheckedAt = Get-Date
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

        # Win32_ComputerSystem.Model costuma trazer so o codigo interno (ex:
        # "83NS" na Lenovo). O nome comercial (ex: "IdeaPad Slim 3 15IRH10")
        # geralmente fica em Win32_ComputerSystemProduct.Version - mas em
        # placas genericas esse campo vem com texto de preenchimento do
        # fabricante da placa-mae, entao so usa se parecer um valor real.
        $csProduct = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
        $modelComercial = if ($csProduct.Version) { $csProduct.Version.Trim() } else { $null }

        # Alem das frases de preenchimento conhecidas, tambem descarta valores
        # curtos demais, so numericos (ex: "00") ou no formato de versao/
        # firmware (ex: "V1.25") - nao sao nome comercial de nada, sao
        # placeholder de fabricante de placa generica/OEM ou versao de BIOS.
        $pareceValorReal = $modelComercial -and
            $modelComercial.Length -ge 4 -and
            $modelComercial -notmatch '^\d+$' -and
            $modelComercial -notmatch '^[Vv]?\d+(\.\d+)+[a-zA-Z]?$' -and
            $modelComercial -notmatch 'To Be Filled|System Version|Not Applicable|^None$|Default string'

        $modeloFinal = if ($pareceValorReal) { $modelComercial } else { $cs.Model }

        $global:cachedMachineSpecs = [PSCustomObject]@{
            manufacturer = $cs.Manufacturer
            model        = $modeloFinal
            serial       = if ($bios) { $bios.SerialNumber } else { $null }
            os_caption   = if ($os) { $os.Caption } else { $null }
            os_version   = if ($os) { $os.Version } else { $null }
            ram_gb       = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        }
    } catch {
        $global:cachedMachineSpecs = $null
    }
    return $global:cachedMachineSpecs
}

# Nome do arquivo da foto do modelo na biblioteca photos-by-model, ex:
# "Dell Inc." + "Vostro 3401" -> "Dell_Vostro_3401". Precisa dar EXATAMENTE o
# mesmo resultado do model_key() de tools/fetch_machine_photo.py, que e quem
# salva as fotos - coberto por teste em tools/tests/test_fetch_machine_photo.py.
function Get-ModelPhotoKey {
    param([string]$Manufacturer, [string]$Model)
    $fabricante = ([regex]::Replace($Manufacturer, '\b(Inc\.?|Corp\.?|Corporation|Ltd\.?|Co\.?|LLC)\b', '', 'IgnoreCase')).Trim(' ', '.')
    $raw = "$($fabricante)_$($Model)".Trim('_')
    return ([regex]::Replace($raw, '[^A-Za-z0-9._-]+', '_')).Trim('_')
}

# Qual arquivo servir para /photos/<nome>: a foto propria em app\photos, se
# existir; senao, quando o pedido e a foto DESTA maquina, a foto do modelo
# dela na biblioteca photos-by-model. Coberto por teste em
# tools/tests/test_fetch_machine_photo.py.
function Resolve-PhotoPath {
    param([string]$FileName)
    if (-not $FileName) { return $null }
    $fotoPropria = Join-Path $AppDir "photos\$FileName"
    if (Test-Path $fotoPropria) { return $fotoPropria }
    if ([System.IO.Path]::GetFileNameWithoutExtension($FileName) -ne $env:COMPUTERNAME) { return $fotoPropria }
    $specs = Get-MachineSpecs
    if (-not ($specs -and $specs.manufacturer -and $specs.model)) { return $fotoPropria }
    $chaveModelo = Get-ModelPhotoKey -Manufacturer $specs.manufacturer -Model $specs.model
    return Join-Path $AppDir "photos-by-model\$chaveModelo.png"
}

function Send-HttpResponse {
    param(
        $Response,
        [string]$Content,
        [string]$ContentType = "text/plain; charset=utf-8",
        [int]$StatusCode = 200
    )
    try {
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $buffer.Length
        $Response.AddHeader("Access-Control-Allow-Origin", "*")
        $Response.AddHeader("Access-Control-Allow-Headers", "Content-Type, Authorization")
        $Response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        $output = $Response.OutputStream
        $output.Write($buffer, 0, $buffer.Length)
        $output.Close()
    } catch {}
}

function Get-JsonData {
    if (Test-Path $dataFile) {
        try {
            return (Get-Content -Path $dataFile -Raw -Encoding UTF8) | ConvertFrom-Json
        } catch {}
    }
    return $null
}

function Save-JsonData($obj) {
    try {
        $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $dataFile -Encoding UTF8
    } catch {}
}

function Test-AuthToken($request) {
    $authHeader = $request.Headers["Authorization"]
    if (-not $authHeader) { return $false }
    $token = $authHeader -replace "^Bearer\s+", ""
    if ($global:activeTokens.ContainsKey($token)) {
        return $true
    }
    return $false
}

function Test-FilaTravada {
    $d = Get-JsonData
    $thresholdMinutes = 5
    if ($d -and $d.settings.stuck_threshold_minutes) {
        $thresholdMinutes = [int]$d.settings.stuck_threshold_minutes
    }

    # Evita reinícios repetidos em cascata (cooldown de 2 minutos)
    $diffCooldown = (Get-Date) - $global:lastAutoRestart
    if ($diffCooldown.TotalMinutes -lt 2) {
        return
    }

    $stuckJobs = @()
    try {
        $printers = Get-Printer -ErrorAction SilentlyContinue
        foreach ($p in $printers) {
            $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
            foreach ($j in $jobs) {
                if ($j.SubmittedTime) {
                    $tempoFila = (Get-Date) - $j.SubmittedTime
                    if ($tempoFila.TotalMinutes -ge $thresholdMinutes) {
                        $stuckJobs += [PSCustomObject]@{
                            Printer = $p.Name
                            DocName = $j.DocumentName
                            Minutes = [Math]::Round($tempoFila.TotalMinutes, 1)
                        }
                    }
                }
            }
        }
    } catch {}

    # Verifica também arquivos .spl abandonados há mais de 5 minutos
    $spoolPath = "$env:SystemRoot\System32\spool\PRINTERS"
    if (Test-Path $spoolPath) {
        $arquivosVelhos = Get-ChildItem -Path $spoolPath -Filter "*.spl" -Force -ErrorAction SilentlyContinue |
            Where-Object { ((Get-Date) - $_.CreationTime).TotalMinutes -ge $thresholdMinutes }
        if ($arquivosVelhos -and $stuckJobs.Count -eq 0) {
            $stuckJobs += [PSCustomObject]@{
                Printer = "Fila Geral"
                DocName = "Arquivo temporário SPL travado"
                Minutes = $thresholdMinutes
            }
        }
    }

    if ($stuckJobs.Count -gt 0) {
        $primeiro = $stuckJobs[0]
        $motivo = "Impressão '$($primeiro.DocName)' travada há $($primeiro.Minutes) min na impressora '$($primeiro.Printer)'"
        Write-Host "[MONITOR AUTO] Detectado travamento! Disparando limpeza automática: $motivo" -ForegroundColor Yellow

        $global:lastAutoRestart = Get-Date

        # Dispara o processo central em nova janela elevada para fornecer visualização ao usuário
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$coreScript`" -IsAutomatic -Reason `"$motivo`" -AppDir `"$AppDir`""
        Start-Process powershell.exe -ArgumentList $argList -WindowStyle Normal
    }
}

# 4. Loop Principal de Execução (Assíncrono + Timer)
$asyncResult = $listener.BeginGetContext($null, $null)
$nextQueueCheck = Get-Date

Write-Host "[MONITOR] Monitoramento do Spooler ativo. Limiar: 5 minutos." -ForegroundColor Cyan

while ($listener.IsListening) {
    # 4.1. Atende Requisições HTTP
    if ($asyncResult.IsCompleted) {
        try {
            $context = $listener.EndGetContext($asyncResult)
            $asyncResult = $listener.BeginGetContext($null, $null)

            $req = $context.Request
            $res = $context.Response
            $path = $req.Url.AbsolutePath
            $method = $req.HttpMethod

            if ($method -eq "OPTIONS") {
                Send-HttpResponse -Response $res -Content ""
                continue
            }

            if ($path -eq "/api/health" -and $method -eq "GET") {
                # Endpoint público (sem autenticação) só com informação não sensível,
                # usado pelo ícone da bandeja (TrayHelper.ps1) e pelo Painel de Frota
                # (visão remota de várias máquinas) para exibir o status.
                $spoolerStatus = (Get-Service -Name Spooler -ErrorAction SilentlyContinue).Status
                $queueCount = 0
                $printerNames = @()
                try {
                    $printers = Get-Printer -ErrorAction SilentlyContinue
                    foreach ($p in $printers) {
                        $printerNames += $p.Name
                        $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
                        if ($jobs) { $queueCount += $jobs.Count }
                    }
                } catch {}

                $installedVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "" }

                $dHealth = Get-JsonData
                $stats = if ($dHealth -and $dHealth.stats) { $dHealth.stats } else { @{ restarts_auto = 0; restarts_manual = 0; total_prints_cleaned = 0 } }
                $lastEvent = if ($dHealth -and $dHealth.history -and $dHealth.history.Count -gt 0) { $dHealth.history[0] } else { $null }

                $diskFreeGb = $null
                $diskTotalGb = $null
                try {
                    $disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
                    if ($disco) {
                        $diskFreeGb = [Math]::Round($disco.FreeSpace / 1GB, 1)
                        $diskTotalGb = [Math]::Round($disco.Size / 1GB, 1)
                    }
                } catch {}

                $respObj = @{
                    spooler_status = if ($spoolerStatus) { $spoolerStatus.ToString() } else { "Unknown" }
                    current_queue = $queueCount
                    hostname = $env:COMPUTERNAME
                    printers = $printerNames
                    anydesk_id = Get-AnyDeskId
                    version = $installedVersion
                    stats = $stats
                    last_event = $lastEvent
                    disk_free_gb = $diskFreeGb
                    disk_total_gb = $diskTotalGb
                }
                Send-HttpResponse -Response $res -Content ($respObj | ConvertTo-Json -Depth 5) -ContentType "application/json"
            }
            elseif ($path -eq "/api/machine-info" -and $method -eq "GET") {
                # Publico (sem autenticacao), mesma logica do /api/health - so
                # dados de inventario (fabricante/modelo/serial/SO), usado na
                # tela inicial publica.
                $specs = Get-MachineSpecs
                Send-HttpResponse -Response $res -Content ($specs | ConvertTo-Json) -ContentType "application/json"
            }
            elseif ($path -like "/photos/*" -and $method -eq "GET") {
                # Serve a foto do equipamento. A foto e por MODELO (biblioteca
                # photos-by-model, uma foto serve pra todas as maquinas iguais);
                # app\photos\<HOSTNAME>.png e so uma excecao opcional, pra quando
                # uma maquina especifica precisa de foto propria.
                # GetFileName descarta qualquer parte de diretorio do path (inclusive
                # tentativas de "..") - so o nome do arquivo em si e usado.
                $fileName = [System.IO.Path]::GetFileName($path)
                $photoPath = Resolve-PhotoPath -FileName $fileName
                if ($photoPath -and (Test-Path $photoPath) -and $fileName -notmatch '\.\.') {
                    try {
                        $bytes = [System.IO.File]::ReadAllBytes($photoPath)
                        $ext = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
                        $contentType = switch ($ext) {
                            ".png"  { "image/png" }
                            ".jpg"  { "image/jpeg" }
                            ".jpeg" { "image/jpeg" }
                            default { "application/octet-stream" }
                        }
                        $res.StatusCode = 200
                        $res.ContentType = $contentType
                        $res.AddHeader("Access-Control-Allow-Origin", "*")
                        $res.ContentLength64 = $bytes.Length
                        $res.OutputStream.Write($bytes, 0, $bytes.Length)
                        $res.OutputStream.Close()
                    } catch {
                        Send-HttpResponse -Response $res -Content "Erro ao ler imagem" -StatusCode 500
                    }
                } else {
                    Send-HttpResponse -Response $res -Content "Not Found" -StatusCode 404
                }
            }
            elseif ($path -eq "/api/check-update" -and $method -eq "GET") {
                # Publico (sem autenticacao) - usado pelo botao "Verificar
                # Atualizações" na tela de login. So informa se ha versao
                # nova - a instalacao em si e sempre feita pelo vigia
                # (WatchdogSpooler.ps1) nos horarios fixos (11h e 15h),
                # nunca por aqui.
                $currentVersion = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "" }
                try {
                    if (-not $updateBaseUrl) { throw "config.json sem update_base_url" }
                    $remoteRaw = (Invoke-WebRequest -Uri "$updateBaseUrl/VERSION" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop).Content
                    $latestVersion = if ($remoteRaw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($remoteRaw).Trim() } else { $remoteRaw.ToString().Trim() }
                    $updateAvailable = $latestVersion -and ($latestVersion -ne $currentVersion)

                    $respObj = @{ current_version = $currentVersion; latest_version = $latestVersion; update_available = $updateAvailable }
                    Send-HttpResponse -Response $res -Content ($respObj | ConvertTo-Json) -ContentType "application/json"
                } catch {
                    $respObj = @{ current_version = $currentVersion; error = "Não foi possível conectar ao servidor de atualização." }
                    Send-HttpResponse -Response $res -Content ($respObj | ConvertTo-Json) -ContentType "application/json" -StatusCode 200
                }
            }
            elseif ($path -eq "/api/update-log" -and $method -eq "GET") {
                # Autenticado: historico das atualizacoes desta maquina (vigia e
                # botao do painel) + saida da ultima execucao do instalador, pra
                # diagnosticar pela Frota sem precisar acessar a maquina.
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }
                $lerFim = {
                    param($arquivo, $n)
                    $p = Join-Path $AppDir $arquivo
                    if (Test-Path $p) { @(Get-Content $p -Tail $n -ErrorAction SilentlyContinue) } else { @() }
                }
                $respObj = @{
                    update_log     = & $lerFim "update.log" 100
                    install_output = & $lerFim "install-output.log" 60
                }
                Send-HttpResponse -Response $res -Content ($respObj | ConvertTo-Json -Depth 3) -ContentType "application/json"
            }
            elseif ($path -eq "/api/machines" -and $method -eq "GET") {
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }
                $d = Get-JsonData
                $machines = if ($d -and $d.machines) { $d.machines } else { @() }
                Send-HttpResponse -Response $res -Content (@{ machines = $machines } | ConvertTo-Json -Depth 5) -ContentType "application/json"
            }
            elseif ($path -eq "/api/machines/add" -and $method -eq "POST") {
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $d = Get-JsonData
                if (-not $d.machines) {
                    $d | Add-Member -MemberType NoteProperty -Name "machines" -Value @() -Force
                }
                $novaMaquina = [PSCustomObject]@{
                    id   = [Guid]::NewGuid().ToString("N")
                    name = $body.name
                    host = $body.host
                }
                $listaAtual = @($d.machines) + $novaMaquina
                $d.machines = $listaAtual
                Save-JsonData $d
                Send-HttpResponse -Response $res -Content (@{ success = $true; machine = $novaMaquina } | ConvertTo-Json) -ContentType "application/json"
            }
            elseif ($path -eq "/api/machines/remove" -and $method -eq "POST") {
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $d = Get-JsonData
                if ($d.machines) {
                    $d.machines = @($d.machines | Where-Object { $_.id -ne $body.id })
                }
                Save-JsonData $d
                Send-HttpResponse -Response $res -Content '{"success":true}' -ContentType "application/json"
            }
            elseif ($path -eq "/" -or $path -eq "/index.html") {
                if (Test-Path $dashFile) {
                    $html = Get-Content -Path $dashFile -Raw -Encoding UTF8
                    Send-HttpResponse -Response $res -Content $html -ContentType "text/html; charset=utf-8"
                } else {
                    Send-HttpResponse -Response $res -Content "<h1>Painel Admin não encontrado.</h1>" -StatusCode 404
                }
            }
            elseif ($path -eq "/api/login" -and $method -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $d = Get-JsonData

                if ($body -and $d -and $body.username -eq $d.auth.username -and $body.password_hash -eq $d.auth.password_hash) {
                    $token = [Guid]::NewGuid().ToString("N")
                    $global:activeTokens[$token] = Get-Date
                    $respObj = @{ success = $true; token = $token }
                    Send-HttpResponse -Response $res -Content ($respObj | ConvertTo-Json) -ContentType "application/json"
                } else {
                    $respObj = @{ success = $false; message = "Usuário ou senha incorretos." }
                    Send-HttpResponse -Response $res -Content ($respObj | ConvertTo-Json) -ContentType "application/json" -StatusCode 401
                }
            }
            elseif ($path -eq "/api/status" -and $method -eq "GET") {
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }

                $d = Get-JsonData
                $spoolerStatus = (Get-Service -Name Spooler -ErrorAction SilentlyContinue).Status

                $queueCount = 0
                try {
                    $printers = Get-Printer -ErrorAction SilentlyContinue
                    foreach ($p in $printers) {
                        $jobs = Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue
                        if ($jobs) { $queueCount += $jobs.Count }
                    }
                } catch {}

                $respObj = @{
                    spooler_status = if ($spoolerStatus) { $spoolerStatus.ToString() } else { "Unknown" }
                    current_queue = $queueCount
                    stats = if ($d.stats) { $d.stats } else { @{} }
                    history = if ($d.history) { $d.history } else { @() }
                }
                Send-HttpResponse -Response $res -Content ($respObj | ConvertTo-Json -Depth 5) -ContentType "application/json"
            }
            elseif ($path -eq "/api/change-password" -and $method -eq "POST") {
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }

                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $d = Get-JsonData

                if ($body.current_hash -eq $d.auth.password_hash) {
                    $d.auth.password_hash = $body.new_hash
                    Save-JsonData $d
                    Send-HttpResponse -Response $res -Content '{"success":true,"message":"Senha atualizada com sucesso!"}' -ContentType "application/json"
                } else {
                    Send-HttpResponse -Response $res -Content '{"success":false,"message":"Senha atual incorreta."}' -ContentType "application/json" -StatusCode 400
                }
            }
            elseif ($path -eq "/api/force-restart" -and $method -eq "POST") {
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }

                # Dispara a limpeza forçada em nova janela visual com privilégios
                $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$coreScript`" -Reason `"Disparado pelo Painel Admin`" -AppDir `"$AppDir`""
                Start-Process powershell.exe -ArgumentList $argList -WindowStyle Normal

                Send-HttpResponse -Response $res -Content '{"success":true,"message":"Comando de reinício enviado!"}' -ContentType "application/json"
            }
            elseif ($path -eq "/api/force-update" -and $method -eq "POST") {
                if (-not (Test-AuthToken $req)) {
                    Send-HttpResponse -Response $res -Content '{"error":"Não autorizado"}' -ContentType "application/json" -StatusCode 401
                    continue
                }

                if (-not $updateBaseUrl) {
                    Send-HttpResponse -Response $res -Content '{"success":false,"message":"Servidor de atualização não configurado (config.json ausente)."}' -ContentType "application/json" -StatusCode 500
                    continue
                }

                try {
                    $updaterScript = Join-Path $AppDir "AtualizarAgora.ps1"
                    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$updaterScript`" -UpdateBaseUrl `"$updateBaseUrl`" -Origem painel"
                    Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden
                    Send-HttpResponse -Response $res -Content '{"success":true,"message":"Atualização iniciada em segundo plano. O Spooler pode reiniciar durante o processo."}' -ContentType "application/json"
                } catch {
                    Send-HttpResponse -Response $res -Content (@{ success = $false; message = "Erro ao iniciar atualização: $_" } | ConvertTo-Json) -ContentType "application/json" -StatusCode 500
                }
            }
            else {
                Send-HttpResponse -Response $res -Content "Not Found" -StatusCode 404
            }
        } catch {
            Write-Host "[HTTP ERRO] $_" -ForegroundColor DarkYellow
        }
    }

    # 4.2. Checagem periódica da fila de impressão a cada 30 segundos
    if ((Get-Date) -ge $nextQueueCheck) {
        Test-FilaTravada
        $nextQueueCheck = (Get-Date).AddSeconds(30)
    }

    Start-Sleep -Milliseconds 200
}

$listener.Close()


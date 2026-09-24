@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
title Instalador - Gerenciador do Spooler de Impressao

:: 1. Verificacao e Auto-Elevacao de Administrador
net session >nul 2>&1
if not errorlevel 1 goto :iniciar_instalacao

echo.
echo ===============================================================
echo   SOLICITANDO PRIVILEGIOS DE ADMINISTRADOR...
echo ===============================================================
echo.
echo   Para instalar o servico em segundo plano e configurar o
echo   Agendador de Tarefas do Windows, sao necessarias permissoes.
echo.
echo   Por favor, clique em "SIM" no aviso de autorizacao (UAC)...
echo ===============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
exit /b

:iniciar_instalacao
cd /d "%~dp0"
cls
echo ===============================================================
echo      INSTALAÇÃO - GERENCIADOR DO SPOOLER DE IMPRESSÃO
echo ===============================================================
echo.

set "TARGET_DIR=C:\ProgramData\GerenciadorSpooler"
set "TASK_NAME=GerenciadorSpoolerMonitor"

echo [1/7] Parando instancias anteriores...
schtasks /end /tn "%TASK_NAME%" >nul 2>&1
taskkill /f /fi "WINDOWTITLE eq *SpoolerMonitor*" >nul 2>&1
powershell -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*SpoolerMonitor.ps1*' -or $_.CommandLine -like '*TrayHelper.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

echo [2/7] Criando pasta do sistema em %TARGET_DIR%...
if not exist "%TARGET_DIR%" mkdir "%TARGET_DIR%" >nul 2>&1

echo [3/7] Copiando arquivos do aplicativo...
if exist "%TARGET_DIR%\data.json" (
    :: Preserva configurações existentes caso já tenha sido configurado
    rem config.json (endereco do servidor de atualizacao) PRECISA estar nesta
    rem lista - sem ele o vigia para de achar a VPS e a maquina nunca mais
    rem atualiza sozinha. Coberto por teste em tools/tests/test_api.py.
    if exist "app\config.json" copy /y "app\config.json" "%TARGET_DIR%\" >nul
    copy /y "app\LimparSpoolerCore.ps1" "%TARGET_DIR%\" >nul
    copy /y "app\dashboard.html" "%TARGET_DIR%\" >nul
    copy /y "app\SpoolerMonitor.ps1" "%TARGET_DIR%\" >nul
    copy /y "app\TrayHelper.ps1" "%TARGET_DIR%\" >nul
    copy /y "app\TrayHelperLauncher.vbs" "%TARGET_DIR%\" >nul
    copy /y "app\WatchdogSpooler.ps1" "%TARGET_DIR%\" >nul
    copy /y "app\AtualizarAgora.ps1" "%TARGET_DIR%\" >nul
    copy /y "app\app-icon.ico" "%TARGET_DIR%\" >nul
    copy /y "app\app-icon-force.ico" "%TARGET_DIR%\" >nul
    if exist "app\photos" xcopy /e /i /y "app\photos" "%TARGET_DIR%\photos\" >nul
    rem Biblioteca de fotos por modelo - e dela que sai a foto da maioria das maquinas.
    if exist "app\photos-by-model" xcopy /e /i /y "app\photos-by-model" "%TARGET_DIR%\photos-by-model\" >nul
    copy /y "VERSION" "%TARGET_DIR%\" >nul
) else (
    xcopy /e /i /y "app\*" "%TARGET_DIR%\" >nul
    copy /y "VERSION" "%TARGET_DIR%\" >nul
)

echo [4/7] Liberando porta 8989 no Firewall do Windows (rede local)...
:: Perfil "any" (inclui Publica) porque em redes com VLAN/Grupo de Trabalho o
:: Windows as vezes classifica a rede interna como "Publica" por engano, o que
:: bloquearia a porta mesmo com o roteador liberando.
netsh advfirewall firewall delete rule name="Gerenciador Spooler - Painel" >nul 2>&1
netsh advfirewall firewall add rule name="Gerenciador Spooler - Painel" dir=in action=allow protocol=TCP localport=8989 profile=any >nul 2>&1

echo [5/7] Configurando Tarefa Agendada no Windows (Segundo Plano)...
:: Cria a tarefa com inicialização no logon do usuário com privilégios máximos
schtasks /create /tn "%TASK_NAME%" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%TARGET_DIR%\SpoolerMonitor.ps1\"" /sc onlogon /rl HIGHEST /f >nul

:: Corrige configuracoes de energia da tarefa - por padrao o Windows cria a
:: tarefa com "nao iniciar/parar se estiver na bateria", o que faz o monitor
:: nao subir de forma confiavel em notebooks (mesmo ligados na tomada, se o
:: Windows demorar a detectar isso no boot). Tambem habilita "iniciar assim
:: que possivel" caso o gatilho de logon seja perdido por algum motivo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t = Get-ScheduledTask -TaskName '%TASK_NAME%'; $s = $t.Settings; $s.DisallowStartIfOnBatteries = $false; $s.StopIfGoingOnBatteries = $false; $s.StartWhenAvailable = $true; Set-ScheduledTask -TaskName '%TASK_NAME%' -Settings $s" >nul 2>&1

:: Encerra qualquer instancia anterior e inicia a tarefa (monitor HTTP + limpeza automatica) imediatamente
schtasks /end /tn "%TASK_NAME%" >nul 2>&1
schtasks /run /tn "%TASK_NAME%" >nul 2>&1

:: Cria o "vigia" - roda como SYSTEM (nao depende de login) a cada 5 minutos
:: e religa o monitor sozinho se ele nao estiver respondendo. Rede de
:: seguranca contra o gatilho "ao fazer logon" nao disparar de forma
:: confiavel (limitacao conhecida do Windows Task Scheduler).
schtasks /create /tn "GerenciadorSpoolerWatchdog" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%TARGET_DIR%\WatchdogSpooler.ps1\"" /sc minute /mo 5 /ru SYSTEM /rl HIGHEST /f >nul

echo [6/7] Configurando icone da bandeja (inicializacao automatica)...
:: O icone roda SEM elevacao, via pasta Inicializar do Windows - o Agendador de
:: Tarefas nao consegue exibir icone na bandeja nesta maquina (limitacao do Windows).
:: O atalho aponta para um lancador .vbs (nao direto pro powershell.exe) porque
:: "-WindowStyle Hidden" nao esconde a janela de forma confiavel quando o
:: Windows Terminal e o app padrao de terminal (padrao no Windows 11) - o vbs
:: usa WScript.Shell.Run com SW_HIDE, que sempre funciona.
set "STARTUP_SHORTCUT="
for /f "usebackq tokens=*" %%S in (`powershell -NoProfile -Command "[Environment]::GetFolderPath('Startup')"`) do set "STARTUP_SHORTCUT=%%S\Gerenciador Spooler - Icone.lnk"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$wsh = New-Object -ComObject WScript.Shell; $sc = $wsh.CreateShortcut('%STARTUP_SHORTCUT%'); $sc.TargetPath = \"$env:SystemRoot\System32\wscript.exe\"; $sc.Arguments = '\"%TARGET_DIR%\TrayHelperLauncher.vbs\"'; $sc.IconLocation = \"%TARGET_DIR%\app-icon.ico\"; $sc.Description = 'Icone de status do Gerenciador de Spooler'; $sc.Save();" >nul 2>&1

:: Abre o icone AGORA, sem elevacao (via explorer.exe, ja que este instalador
:: esta rodando elevado e um Start-Process direto herdaria a elevacao, o que
:: reintroduziria o mesmo bug do icone sumido).
start "" explorer.exe "%STARTUP_SHORTCUT%"

echo [7/8] Criando atalhos na Area de Trabalho...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$wsh = New-Object -ComObject WScript.Shell; $desktop = [Environment]::GetFolderPath('Desktop'); $s1 = $wsh.CreateShortcut(\"$desktop\Painel Admin - Spooler.lnk\"); $edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; if (Test-Path $edge) { $s1.TargetPath = $edge; $s1.Arguments = '--app=http://127.0.0.1:8989'; } else { $s1.TargetPath = 'http://127.0.0.1:8989'; } $s1.IconLocation = \"%TARGET_DIR%\app-icon.ico\"; $s1.Description = 'Painel Administrativo do Spooler de Impressao'; $s1.Save(); $s2 = $wsh.CreateShortcut(\"$desktop\Limpar Fila de Impressao.lnk\"); $s2.TargetPath = \"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe\"; $s2.Arguments = \"-NoProfile -ExecutionPolicy Bypass -File `\"%TARGET_DIR%\LimparSpoolerCore.ps1`\"\"; $s2.IconLocation = \"%TARGET_DIR%\app-icon-force.ico\"; $s2.Save(); $b = [System.IO.File]::ReadAllBytes(\"$desktop\Limpar Fila de Impressao.lnk\"); $b[0x15] = $b[0x15] -bor 0x20; [System.IO.File]::WriteAllBytes(\"$desktop\Limpar Fila de Impressao.lnk\", $b);" >nul 2>&1

echo [8/8] Criando atalhos no Menu Iniciar (backup, todos os usuarios)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$wsh = New-Object -ComObject WScript.Shell; $startMenu = \"$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Gerenciador do Spooler\"; if (-not (Test-Path $startMenu)) { New-Item -ItemType Directory -Path $startMenu -Force | Out-Null }; $s1 = $wsh.CreateShortcut(\"$startMenu\Painel Admin - Spooler.lnk\"); $edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; if (Test-Path $edge) { $s1.TargetPath = $edge; $s1.Arguments = '--app=http://127.0.0.1:8989'; } else { $s1.TargetPath = 'http://127.0.0.1:8989'; } $s1.IconLocation = \"%TARGET_DIR%\app-icon.ico\"; $s1.Description = 'Painel Administrativo do Spooler de Impressao'; $s1.Save(); $s2 = $wsh.CreateShortcut(\"$startMenu\Limpar Fila de Impressao.lnk\"); $s2.TargetPath = \"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe\"; $s2.Arguments = \"-NoProfile -ExecutionPolicy Bypass -File `\"%TARGET_DIR%\LimparSpoolerCore.ps1`\"\"; $s2.IconLocation = \"%TARGET_DIR%\app-icon-force.ico\"; $s2.Save(); $b = [System.IO.File]::ReadAllBytes(\"$startMenu\Limpar Fila de Impressao.lnk\"); $b[0x15] = $b[0x15] -bor 0x20; [System.IO.File]::WriteAllBytes(\"$startMenu\Limpar Fila de Impressao.lnk\", $b);" >nul 2>&1

:: Limpa o cache de icones do Windows - sem isso, o Explorer as vezes continua
:: mostrando o icone antigo de um atalho mesmo depois dele ser atualizado
:: (bug de cache conhecido do Windows, nao e algo que o nosso app causa, mas
:: acontece toda vez que trocamos o icone de um atalho ja existente).
ie4uinit.exe -ClearIconCache >nul 2>&1

echo.
echo ===============================================================
echo   [SUCESSO] INSTALACAO CONCLUIDA COM SUCESSO!
echo ===============================================================
echo.
echo   O Gerenciador do Spooler agora esta ativo em segundo plano:
echo   - Monitora travamentos (> 5 minutos) e limpa automaticamente.
echo   - Painel Admin disponivel em: http://127.0.0.1:8989
echo   - Icone de status na bandeja (perto do relogio - pode estar
echo     na seta de icones ocultos "^" na primeira vez).
echo.
echo   Foram adicionados a sua Area de Trabalho:
echo   - [Painel Admin - Spooler] (Login: admin / admin)
echo   - [Limpar Fila de Impressao] (Execucao manual imediata)
echo.
echo ===============================================================
echo.
if /i "%1"=="/silent" goto :fim
echo Pressione qualquer tecla para finalizar...
pause >nul
:fim


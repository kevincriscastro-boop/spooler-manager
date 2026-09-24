@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
title Desinstalador - Gerenciador do Spooler de Impressao

:: 1. Verificacao e Auto-Elevacao de Administrador
net session >nul 2>&1
if not errorlevel 1 goto :iniciar_desinstalacao

echo.
echo ===============================================================
echo   SOLICITANDO PRIVILEGIOS DE ADMINISTRADOR...
echo ===============================================================
echo.
echo   Por favor, clique em "SIM" no aviso de autorizacao (UAC)...
echo ===============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
exit /b

:iniciar_desinstalacao
cls
echo ===============================================================
echo     DESINSTALAÇÃO - GERENCIADOR DO SPOOLER DE IMPRESSÃO
echo ===============================================================
echo.

set "TARGET_DIR=C:\ProgramData\GerenciadorSpooler"
set "TASK_NAME=GerenciadorSpoolerMonitor"

echo [1/6] Encerrando processos e tarefas em segundo plano...
schtasks /end /tn "%TASK_NAME%" >nul 2>&1
schtasks /delete /tn "%TASK_NAME%" /f >nul 2>&1
schtasks /end /tn "GerenciadorSpoolerWatchdog" >nul 2>&1
schtasks /delete /tn "GerenciadorSpoolerWatchdog" /f >nul 2>&1
powershell -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*SpoolerMonitor.ps1*' -or $_.CommandLine -like '*TrayHelper.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1

echo [2/6] Removendo icone da bandeja (pasta Inicializar)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$startup = [Environment]::GetFolderPath('Startup'); Remove-Item \"$startup\Gerenciador Spooler - Icone.lnk\" -Force -ErrorAction SilentlyContinue;" >nul 2>&1

echo [3/7] Removendo atalhos da Area de Trabalho...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$desktop = [Environment]::GetFolderPath('Desktop'); Remove-Item \"$desktop\Painel Admin - Spooler.lnk\" -Force -ErrorAction SilentlyContinue; Remove-Item \"$desktop\Limpar Fila de Impressao.lnk\" -Force -ErrorAction SilentlyContinue;" >nul 2>&1

echo [4/7] Removendo atalhos do Menu Iniciar...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$startMenu = \"$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Gerenciador do Spooler\"; Remove-Item $startMenu -Recurse -Force -ErrorAction SilentlyContinue;" >nul 2>&1

echo [5/7] Removendo regra de Firewall...
netsh advfirewall firewall delete rule name="Gerenciador Spooler - Painel" >nul 2>&1

echo [6/7] Removendo arquivos do sistema em %TARGET_DIR%...
if exist "%TARGET_DIR%" (
    rmdir /s /q "%TARGET_DIR%" >nul 2>&1
)

echo [7/7] Finalizando limpeza...

echo.
echo ===============================================================
echo   [SUCESSO] O aplicativo foi completamente desinstalado!
echo ===============================================================
echo.
echo Pressione qualquer tecla para fechar esta janela...
pause >nul


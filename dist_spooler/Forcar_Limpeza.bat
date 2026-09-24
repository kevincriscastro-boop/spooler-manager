@echo off
chcp 65001 >nul
title Forcar Limpeza do Spooler de Impressao

:: 1. Verificacao e Auto-Elevacao de Administrador
net session >nul 2>&1
if not errorlevel 1 goto :executar_limpeza

echo.
echo ===============================================================
echo   SOLICITANDO PRIVILEGIOS DE ADMINISTRADOR...
echo ===============================================================
echo.
echo   Clique em "SIM" no aviso de autorizacao (UAC)...
echo ===============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
exit /b

:executar_limpeza
set "SCRIPT_PATH=%~dp0app\LimparSpoolerCore.ps1"
if not exist "%SCRIPT_PATH%" set "SCRIPT_PATH=C:\ProgramData\GerenciadorSpooler\LimparSpoolerCore.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -Reason "Forçado manualmente via arquivo executável"

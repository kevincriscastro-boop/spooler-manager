@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
title Reinstalador - Gerenciador do Spooler de Impressao

:: 1. Verificacao e Auto-Elevacao de Administrador
net session >nul 2>&1
if not errorlevel 1 goto :iniciar_reinstalacao

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

:iniciar_reinstalacao
cd /d "%~dp0"
cls
echo ===============================================================
echo     REINSTALAÇÃO - GERENCIADOR DO SPOOLER DE IMPRESSÃO
echo ===============================================================
echo.

echo [Etapa 1/2] Executando desinstalacao previa...
call "%~dp0Desinstalar.bat"

echo.
echo [Etapa 2/2] Iniciando nova instalacao limpa...
call "%~dp0Instalar.bat"

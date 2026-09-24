@echo off
chcp 65001 >nul
title Painel Admin - Spooler Manager

set "EDGE=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=C:\Program Files\Microsoft\Edge\Application\msedge.exe"

if exist "%EDGE%" (
    start "" "%EDGE%" --app=http://127.0.0.1:8989
) else (
    start http://127.0.0.1:8989
)
exit /b

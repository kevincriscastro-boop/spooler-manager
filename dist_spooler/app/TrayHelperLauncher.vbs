' Lanca o TrayHelper.ps1 completamente oculto, sem nenhuma janela visivel.
' Usa WScript.Shell.Run com o parametro 0 (SW_HIDE) - isso esconde a janela
' no nivel do Windows, ao contrario do "-WindowStyle Hidden" do PowerShell,
' que nao funciona de forma confiavel quando o Windows Terminal e o app
' padrao de terminal (comportamento padrao a partir do Windows 11).
Set objShell = CreateObject("WScript.Shell")
scriptPath = "C:\ProgramData\GerenciadorSpooler\TrayHelper.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """"
objShell.Run cmd, 0, False

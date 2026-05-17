@echo off
:: Run as Administrator check
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This script requires Administrator privileges.
    echo Requesting elevation...
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d %CD% && %~nx0' -Verb RunAs"
    exit /b
)

echo Downloading Remove-Windows-Updates script...
powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/waqarhossen/Remove-Windows-Updates/main/remove-updates.ps1' -OutFile 'remove-updates.ps1'"

echo Running script...
powershell -ExecutionPolicy Bypass -File ".\remove-updates.ps1"
pause

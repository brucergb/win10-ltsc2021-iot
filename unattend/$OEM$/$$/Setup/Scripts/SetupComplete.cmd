@echo off
rem Se ejecuta como SYSTEM al terminar Windows Setup, antes del primer inicio de sesion.
rem Logs en C:\Windows\Setup\Scripts\*.log
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\install-defaults.ps1" > "%WINDIR%\Setup\Scripts\install-defaults.log" 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\hardening.ps1" > "%WINDIR%\Setup\Scripts\hardening.log" 2>&1
exit /b 0

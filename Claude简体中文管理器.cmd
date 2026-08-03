@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\claude_zh_manager.ps1" -Action gui
endlocal

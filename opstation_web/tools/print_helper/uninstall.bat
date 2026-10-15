@echo off
title Opstation Print Helper - Uninstall
taskkill /im OpstationPrint.exe /f >nul 2>&1
del /q "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Opstation Print Helper.lnk" >nul 2>&1
rmdir /s /q "%LOCALAPPDATA%\OpstationPrint" >nul 2>&1
echo Opstation Print Helper removed.
pause

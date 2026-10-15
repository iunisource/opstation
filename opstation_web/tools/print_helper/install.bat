@echo off
title Opstation Print Helper - Install
set "D=%LOCALAPPDATA%\OpstationPrint"
if not exist "%D%" mkdir "%D%"
taskkill /im OpstationPrint.exe /f >nul 2>&1
copy /y "%~dp0OpstationPrint.exe" "%D%\OpstationPrint.exe" >nul
if errorlevel 1 (
  echo Could not copy the helper. Close it if running and try again.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup')+'\Opstation Print Helper.lnk'); $s.TargetPath='%D%\OpstationPrint.exe'; $s.WorkingDirectory='%D%'; $s.Save()"
start "" "%D%\OpstationPrint.exe"
echo.
echo  Opstation Print Helper is installed and running.
echo  It starts automatically when Windows starts.
echo  Now open Opstation and press "Print labels".
echo.
pause

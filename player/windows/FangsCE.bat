@echo off
setlocal EnableDelayedExpansion
title Fangs: Community Edition
cd /d "%~dp0"

set "EXE=MOBA\Binaries\Win64\MOBA-Win64-Shipping.exe"
if not exist "%EXE%" set "EXE=MOBA\Binaries\Win64\MOBA.exe"
if not exist "%EXE%" (
  echo This launcher must be inside your FANGS game folder - the folder that contains "MOBA".
  pause
  exit /b 1
)

set "ACCOUNT=FangsCE\account.txt"
if exist "%ACCOUNT%" goto launch

echo.
echo   Welcome to Fangs: Community Edition!
echo   Unofficial fan project - not affiliated with the owners of FANGS.
echo.
:askname
set "NAME="
set /p "NAME=  Choose your player name (letters/numbers, 3-16 characters): "
if "!NAME:~2,1!"=="" (echo   At least 3 characters please. & goto askname)
if not "!NAME:~16!"=="" (echo   Max 16 characters. & goto askname)
rem strip every allowed character - anything left over is not allowed (replacement is case-insensitive)
set "CHK=!NAME!"
for %%C in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z 0 1 2 3 4 5 6 7 8 9 _) do set "CHK=!CHK:%%C=!"
if not "!CHK!"=="" (echo   Only letters, numbers and _ please. & goto askname)
rem Per-install secret: the server ties your name to it on first login.
set "SECRET=!RANDOM!!RANDOM!!RANDOM!!RANDOM!!RANDOM!!RANDOM!!RANDOM!!RANDOM!"
(echo !NAME!& echo !SECRET!) > "%ACCOUNT%"
echo   Saved. Your name is tied to this install - keep FangsCE\account.txt to keep it.

:launch
set "NAME="
set "SECRET="
for /f "usebackq delims=" %%L in ("%ACCOUNT%") do (
  if not defined NAME (set "NAME=%%L") else if not defined SECRET (set "SECRET=%%L")
)
rem Re-apply the server connection settings every launch. Release (Shipping) builds read them from
rem %LOCALAPPDATA%\MOBA\Saved, developer builds from the game folder - write both.
for %%D in ("MOBA\Saved\Config\WindowsNoEditor" "%LOCALAPPDATA%\MOBA\Saved\Config\WindowsNoEditor") do (
  if not exist "%%~D" mkdir "%%~D"
  copy /y "FangsCE\Engine.ini" "%%~D\Engine.ini" >nul
)
set "PASS=!SECRET!"
if exist "FangsCE\joincode.txt" (
  set /p CODE=<"FangsCE\joincode.txt"
  set "PASS=!CODE!:!SECRET!"
)
echo   Starting FANGS as !NAME! ...
start "" "%EXE%" -TestUser=!NAME! -TestPass=!PASS!
endlocal

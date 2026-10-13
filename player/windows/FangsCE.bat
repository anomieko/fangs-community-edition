@echo off
rem Fangs: Community Edition launcher. Fetches player-file updates from the server (never game files),
rem then starts the game via FangsCE\launch.cmd. Uses curl.exe and tar.exe, built into Windows 10/11.
rem This file is never replaced by an update (Windows reads a running .bat as it goes).
title Fangs: Community Edition
cd /d "%~dp0"

if not exist "FangsCE\update-url.txt" goto launch
where /q curl.exe || goto launch
where /q tar.exe || goto launch
set "URL=" & set "LATEST=" & set "CURRENT="
set /p URL=<"FangsCE\update-url.txt"
echo   Checking for updates...
curl.exe -s -f -m 15 -o "FangsCE\latest.txt" "%URL%FangsCE-Update.txt" || goto offline
set /p LATEST=<"FangsCE\latest.txt"
if exist "FangsCE\version.txt" set /p CURRENT=<"FangsCE\version.txt"
if "%LATEST%"=="%CURRENT%" goto launch
echo   Downloading update %LATEST% ...
curl.exe -s -f -m 900 -o "FangsCE\update.zip" "%URL%FangsCE-Update.zip" || goto updatefailed
tar -xf "FangsCE\update.zip" || goto updatefailed
copy /y "FangsCE\latest.txt" "FangsCE\version.txt" >nul
del "FangsCE\update.zip" 2>nul
echo   Updated.
goto launch

:offline
echo   Could not reach the server - is it up? Starting anyway.
goto launch

:updatefailed
del "FangsCE\update.zip" 2>nul
echo   Update failed - starting the version you have.

:launch
if exist "FangsCE\launch.cmd" (
  call "FangsCE\launch.cmd"
) else (
  echo   FangsCE\launch.cmd is missing - please re-download the client.
  pause
)

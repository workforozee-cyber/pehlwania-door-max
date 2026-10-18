@echo off
rem ============================================================
rem  Pehlwania Door Max - POS launcher
rem  Opens the POS in its own app window (Edge or Chrome).
rem  All data is stored in the "AppData" folder next to this file.
rem  Keep this .bat and the .html file together in the same folder.
rem ============================================================
setlocal
set "DIR=%~dp0"
set "APP=%DIR%PehlwaniaDoorMax-POS.html"
set "DATA=%DIR%AppData"
set "URL=file:///%APP:\=/%"

set "BR="
if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set "BR=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not defined BR if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" set "BR=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if not defined BR if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "BR=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined BR if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "BR=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"

if defined BR (
  start "" "%BR%" --app="%URL%" --user-data-dir="%DATA%" --no-first-run --no-default-browser-check
) else (
  rem No Edge/Chrome found - open in the default browser instead.
  start "" "%APP%"
)
endlocal

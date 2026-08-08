@echo off
setlocal
cd /d "%~dp0"

call "%~dp0runtime-env.bat"
if errorlevel 1 (
  echo.
  pause
  exit /b 1
)

if not defined MEDIA_NORMALIZER_RUNTIME_ROOT (
  echo This is a source checkout without a bundled portable runtime.
  echo Run rebuild-media-normalizer.bat first.
  echo.
  pause
  exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime-check.ps1" -RuntimeRoot "%MEDIA_NORMALIZER_RUNTIME_ROOT%"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXIT_CODE%

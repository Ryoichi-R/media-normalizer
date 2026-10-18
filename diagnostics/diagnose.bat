@echo off
setlocal
call "%~dp0runtime-env.bat"
if errorlevel 1 (
  echo Bundled runtime validation failed.
  pause
  exit /b 1
)
echo === media-normalizer diagnose ===
echo Errors will appear in this window.
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0diagnose.ps1"
echo.
echo diagnose.log: "%~dp0diagnose.log"
echo === done ===
pause
endlocal

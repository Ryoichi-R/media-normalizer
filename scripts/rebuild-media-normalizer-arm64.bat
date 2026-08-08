@echo off
setlocal
cd /d "%~dp0"

where pwsh.exe >nul 2>&1
if errorlevel 1 (
  echo PowerShell 7 ^(pwsh.exe^) was not found.
  echo Install PowerShell 7 on the build machine and try again.
  pause
  exit /b 1
)

set "CLEAN_SWITCH="
set "BUILD_LABEL=rebuild"
if /I "%~1"=="--clean" (
  set "CLEAN_SWITCH=-CleanBuild"
  set "BUILD_LABEL=complete clean rebuild"
  shift
)

if not "%~2"=="" (
  echo Only one output parent folder can be specified.
  echo Usage: rebuild-media-normalizer-arm64.bat [--clean] [output parent folder]
  pause
  exit /b 2
)

if "%~1"=="" (
  pwsh.exe -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0rebuild-media-normalizer.ps1" -Runtime win-arm64 -SelectOutputRoot %CLEAN_SWITCH%
) else (
  pwsh.exe -STA -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0rebuild-media-normalizer.ps1" -Runtime win-arm64 -OutputRoot "%~f1" %CLEAN_SWITCH%
)
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="3" (
  echo Media Normalizer ARM64 %BUILD_LABEL% was cancelled. No files were generated.
  pause
  exit /b 3
)
if not "%EXIT_CODE%"=="0" (
  echo Media Normalizer ARM64 %BUILD_LABEL% failed. Review the error above.
  pause
  exit /b %EXIT_CODE%
)

echo Media Normalizer ARM64 %BUILD_LABEL% completed successfully.
pause
exit /b 0

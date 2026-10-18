@echo off
set "MEDIA_NORMALIZER_RUNTIME_ROOT=%~dp0runtime"

if not exist "%MEDIA_NORMALIZER_RUNTIME_ROOT%\dependency-manifest.json" (
  if exist "%~dp0portable-package.marker" (
    echo Bundled runtime manifest was not found.
    exit /b 1
  )
  set "MEDIA_NORMALIZER_RUNTIME_ROOT="
  exit /b 0
)

set "PATH=%MEDIA_NORMALIZER_RUNTIME_ROOT%\ffmpeg\bin;%MEDIA_NORMALIZER_RUNTIME_ROOT%\python;%PATH%"
set "PYTHONHOME=%MEDIA_NORMALIZER_RUNTIME_ROOT%\python"
set "PYTHONPATH=%MEDIA_NORMALIZER_RUNTIME_ROOT%\python\Lib\site-packages"
set "FFMPEG_PATH=%MEDIA_NORMALIZER_RUNTIME_ROOT%\ffmpeg\bin\ffmpeg.exe"

if "%MEDIA_NORMALIZER_RUNTIME_VALIDATED%"=="1" exit /b 0

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime-check.ps1" -RuntimeRoot "%MEDIA_NORMALIZER_RUNTIME_ROOT%" -Quiet
if errorlevel 1 (
  echo.
  echo The bundled Media Normalizer runtime failed validation.
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0runtime-check.ps1" -RuntimeRoot "%MEDIA_NORMALIZER_RUNTIME_ROOT%"
  exit /b 1
)

set "MEDIA_NORMALIZER_RUNTIME_VALIDATED=1"
exit /b 0

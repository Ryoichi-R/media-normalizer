@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0MediaNormalizer.exe" (
  echo MediaNormalizer.exe is missing.
  exit /b 1
)
"%~dp0MediaNormalizer.exe" %*
exit /b %ERRORLEVEL%

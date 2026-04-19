@echo off
setlocal EnableExtensions

set "SCRIPT_PATH=%~dp0scripts\generate-readme.ps1"
set "NEW_THEME_SCRIPT=%~dp0scripts\new-theme.ps1"
set "PS_EXE=powershell"

where pwsh >nul 2>nul
if not errorlevel 1 set "PS_EXE=pwsh"

set "subcmd=%~1"

if "%subcmd%"=="" goto run_generate
if "%subcmd:~0,1%"=="-" goto run_generate_with_args
if /I "%subcmd%"=="generatereadme" goto run_generate_with_shift
if /I "%subcmd%"=="png-url" goto run_png_url
if /I "%subcmd%"=="doctor" goto run_doctor_with_shift
if /I "%subcmd%"=="new-theme" goto run_new_theme
if /I "%subcmd%"=="help" goto show_help
if /I "%subcmd%"=="-h" goto show_help
if /I "%subcmd%"=="--help" goto show_help

echo Unknown command: %subcmd%
goto show_help_error

:run_generate_with_shift
if "%~2"=="" (
  call :invoke_generate
) else (
  set "forwardArgs=%*"
  set "forwardArgs=%forwardArgs:* =%"
  call :invoke_generate %forwardArgs%
)
exit /b %errorlevel%

:run_generate
call :invoke_generate
exit /b %errorlevel%

:run_generate_with_args
call :invoke_generate %*
exit /b %errorlevel%

:run_doctor_with_shift
if "%~2"=="" (
  call :invoke_generate -Doctor
) else (
  call :invoke_generate -Doctor -Folder "%~2"
)
exit /b %errorlevel%

:run_new_theme
if "%~2"=="" (
  call :invoke_new_theme
) else (
  set "forwardArgs=%*"
  set "forwardArgs=%forwardArgs:* =%"
  call :invoke_new_theme %forwardArgs%
)
exit /b %errorlevel%

:run_png_url
if "%~2"=="" (
  echo Usage: themecmd.cmd png-url "path\\to\\image.png"
  exit /b 1
)
call :invoke_generate -PredictPngRawUrl "%~2"
exit /b %errorlevel%

:invoke_generate
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*
exit /b %errorlevel%

:invoke_new_theme
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%NEW_THEME_SCRIPT%" %*
exit /b %errorlevel%

:show_help
call :print_help
exit /b 0

:show_help_error
call :print_help
exit /b 1

:print_help
echo themecmd usage:
echo   themecmd.cmd [generatereadme] [options]
echo   themecmd.cmd new-theme [options]
echo   themecmd.cmd png-url "path\\to\\image.png"
echo   themecmd.cmd doctor [options]
echo.
echo Examples:
echo   themecmd.cmd
echo   themecmd.cmd generatereadme -NoAuthorPrompt
echo   themecmd.cmd generatereadme -OutputPath "README temp.md"
echo   themecmd.cmd new-theme
echo   themecmd.cmd new-theme -Name "My Theme" -Author "YourName" -Folder "Silver Themes"
echo   themecmd.cmd png-url "Silver Themes\\Legoshi\\legoshi.png"
echo   themecmd.cmd doctor
echo.
echo Docs:
echo   THEMECMD.md
exit /b 0

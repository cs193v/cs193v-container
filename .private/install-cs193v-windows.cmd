@echo off
setlocal EnableDelayedExpansion
::
:: CS193V setup for Windows — stage one.
::
:: HOW TO RUN THIS: right-click the file and choose "Run as administrator".
::
:: A .cmd file is used rather than a .ps1 on purpose. A downloaded PowerShell script is
:: blocked by both the execution policy and the mark-of-the-web, so it would need
:: Unblock-File or -ExecutionPolicy Bypass first — which is confusing, and teaches
:: students to click past security warnings in a course about not trusting code. A .cmd
:: just runs. Where batch is a poor tool, this shells out to short PowerShell commands.
::
:: This is a TWO-STAGE setup, because installing WSL requires a restart. Run this file,
:: restart when it says to, then run it AGAIN. It is safe to run any number of times.
::
:: Stage 1 (here) : install WSL and the CS193V Linux environment
:: Stage 2 (auto) : run install-cs193v.sh inside it — the same script macOS and Linux use

set "DISTRO=CS193V"
set "IMAGE_NAME=Ubuntu-26.04"
set "HERE=%~dp0"

echo.
echo   CS193V setup for Windows
echo   ------------------------
echo.

:: ---- must be Administrator ----------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
  echo   This needs to run as Administrator, because installing WSL is a
  echo   Windows feature change.
  echo.
  echo   Close this window, then RIGHT-CLICK install-cs193v-windows.cmd and
  echo   choose "Run as administrator".
  echo.
  pause
  exit /b 1
)

:: ---- is WSL present at all? ---------------------------------------------------
where wsl.exe >nul 2>&1
if errorlevel 1 goto installwsl

wsl.exe --status >nul 2>&1
if errorlevel 1 goto installwsl
goto havewsl

:installwsl
echo   [1/3] Installing WSL. This is a Windows feature, so it needs a restart.
echo.
wsl.exe --update
wsl.exe --install --no-distribution
echo.
echo   ------------------------------------------------------------------
echo   RESTART YOUR COMPUTER NOW.
echo.
echo   After it restarts, run this same file again (right-click, Run as
echo   administrator) and it will carry on from here.
echo   ------------------------------------------------------------------
echo.
pause
exit /b 0

:havewsl
echo   [1/3] WSL is installed.

:: ---- does the CS193V environment exist? --------------------------------------
:: Batch cannot read `wsl --list` reliably: its output is UTF-16, which breaks findstr.
:: WSL_UTF8 makes it plain text, and PowerShell does the comparison.
set "HAVE=no"
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "$env:WSL_UTF8=1; if ((wsl.exe -l -q) -match '^%DISTRO%$') {'yes'} else {'no'}"`) do set "HAVE=%%i"

if /i "!HAVE!"=="yes" (
  echo   [2/3] The %DISTRO% environment already exists.
) else (
  echo   [2/3] Creating the %DISTRO% Linux environment.
  echo.
  echo         Ubuntu will ask you to choose a username and password for it.
  echo         Pick anything you like and write it down - you will need the
  echo         password occasionally, and it is separate from your Windows one.
  echo.
  wsl.exe --install -d %IMAGE_NAME% --name %DISTRO%
  if errorlevel 1 (
    echo.
    echo   Could not create the %DISTRO% environment.
    echo.
    echo   Your version of WSL may not support naming a new environment.
    echo   Please send course staff the output of:   wsl --version
    echo   and do not spend time troubleshooting this.
    echo.
    pause
    exit /b 1
  )
)

:: ---- hand over to the real installer ----------------------------------------
if not exist "%HERE%install-cs193v.sh" (
  echo.
  echo   Could not find install-cs193v.sh next to this file.
  echo.
  echo   Both files need to be in the same folder - download install-cs193v.sh
  echo   into %HERE% and run this again.
  echo.
  pause
  exit /b 1
)

echo   [3/3] Setting up the container inside %DISTRO%.
echo.

:: Translate the Windows path to the Linux path WSL sees. wslpath handles spaces.
set "LINUXPATH="
for /f "usebackq delims=" %%i in (`wsl.exe -d %DISTRO% -e wslpath -a "%HERE%install-cs193v.sh"`) do set "LINUXPATH=%%i"

if "!LINUXPATH!"=="" (
  echo   Could not work out where %DISTRO% sees this folder.
  echo   Please send this whole window to course staff.
  echo.
  pause
  exit /b 1
)

wsl.exe -d %DISTRO% -e bash "!LINUXPATH!"
set "RC=!errorlevel!"

echo.
if "!RC!"=="0" (
  echo   ------------------------------------------------------------------
  echo   Done. From now on you work inside the %DISTRO% environment:
  echo.
  echo       wsl -d %DISTRO%
  echo       cd ~/cs193v
  echo       ./cs193v
  echo.
  echo   You can also open %DISTRO% from the Windows Terminal dropdown.
  echo   Your project files are reachable from Windows at:
  echo       \\wsl.localhost\%DISTRO%\home\<your-linux-username>\cs193v\projects
  echo   ------------------------------------------------------------------
) else (
  echo   Setup did not finish - see the messages above.
  echo   It is safe to run this file again once the problem is fixed.
)
echo.
pause
exit /b !RC!

@echo off
setlocal
::
:: CS193V setup for Windows -- stage one.
::
:: HOW TO RUN THIS: right-click the file and choose "Run as administrator".
::
:: A .cmd file is used rather than a .ps1 on purpose. A downloaded PowerShell script is
:: blocked by both the execution policy and the mark-of-the-web, so it would need
:: Unblock-File or -ExecutionPolicy Bypass first -- which is confusing, and teaches
:: students to click past security warnings in a course about not trusting code. A .cmd
:: just runs. Where batch is a poor tool, this shells out to short PowerShell commands.
::
:: This is a TWO-STAGE setup, because installing WSL requires a restart. Run this file,
:: restart when it says to, then run it AGAIN. It is safe to run any number of times.
::
:: Stage 1 (here) : install WSL and the CS193V Linux environment
:: Stage 2 (auto) : run install-cs193v.sh inside it -- the same script macOS and Linux use
::
:: ---------------------------------------------------------------------------------
:: THE BATCH SUBSET THIS FILE KEEPS TO, AND WHY
::
:: Every construct here is one the test suite can verify. That is not a style
:: preference: .private/tests/27-installer-windows.sh executes this file under wine's
:: cmd.exe, and .private/tests/25-installer.sh enforces the rules below statically for
:: the cases no execution can reach. Deliberately avoided:
::
::   * DELAYED EXPANSION. `setlocal EnableDelayedExpansion` silently deletes `!` from
::     anything expanded in the earlier percent phase, so `set "HERE=%~dp0"` run from
::     C:\Users\bob\Down!loads\ yields Downloads\ -- a plausible, wrong path. Measured.
::   * `if errorlevel N`. It is a `>=` test, so it is FALSE for negative codes, and
::     wsl.exe returns -1 for every failure. Use `if %errorlevel% neq 0`.
::   * `for /f` BACKTICKS, entirely. They run a nested cmd /c, which doubles every escaping
::     rule, and they SWALLOW the command exit code -- which is how an error message ends up
::     being used as a value. Redirect to a file and read that instead.
::   * PARENTHESISED if/else BLOCKS. Inside one, `%VAR%` freezes at parse time and a
::     bare `)` in a message closes the block early. `goto` labels have neither problem.
::   * `< > | & ( )` IN MESSAGE TEXT. cmd extracts redirection before echo runs, so the
::     line prints NOTHING rather than printing wrongly. Quote the value or drop the
::     character.
::   * `::` INSIDE A BLOCK, and non-ASCII bytes. Batch is decoded as OEM with no UTF-8
::     support, and `chcp` cannot change it.
::   * PIPES. wine implements them with a temp file and loses batch context in the stages;
::     a stage it cannot launch aborts the whole script with exit 255. Measured. Nothing
::     here needs one, so nothing here has one.
::
:: %HERE% IS QUOTED AT EVERY USE. A student can download into "cs193v (1)" -- which is
:: what a browser names a second copy -- and an unquoted %HERE% makes that a syntax error.
:: ---------------------------------------------------------------------------------

set "DISTRO=CS193V"
set "IMAGE_NAME=Ubuntu-26.04"
set "HERE=%~dp0"

:: One probe, used twice: before creating the environment and again afterwards. Batch cannot
:: read `wsl --list` directly -- its output is UTF-16, which breaks findstr and for /f alike --
:: so WSL_UTF8 makes it plain text and PowerShell does the comparison. The answer comes back
:: as an EXIT CODE rather than on stdout: 0 = present, 1 = absent, anything else = the probe
:: itself could not run, which is a different thing from "absent" and is handled separately.
set "PROBE=$env:WSL_UTF8=1; if ((wsl.exe -l -q) -match '^%DISTRO%$') { exit 0 } else { exit 1 }"

echo.
echo   CS193V setup for Windows
echo   ------------------------
echo.

:: ---- must be Administrator ----------------------------------------------------
:: NOT `net session`: that idiom returns errorlevel 2 when the Server service is stopped,
:: which hardening baselines routinely do, so a real Administrator is told they are not one.
::
:: HKU\S-1-5-19 is the LOCAL SERVICE hive, which only an elevated process can read. One
:: command, one exit code: no dependency on a service being started, none on the console
:: language, and it works from a 32-bit process because reg.exe exists in both System32 and
:: SysWOW64. It also succeeds for SYSTEM, so a management agent running this is not locked
:: out.
::
:: The `whoami /groups | findstr S-1-16-12288` form reads the integrity level directly and is
:: the more precise test, but it needs a PIPE. In batch a pipe runs each side in a child cmd,
:: which loses the calling script context and is a well-known source of quoting surprises --
:: so avoiding one for a question a single command can answer is the better trade regardless.
:: Corroborated the hard way: under wine that pipe does not merely misbehave, it aborts the
:: whole script with exit 255, which is also why no test could have covered it.
reg query "HKU\S-1-5-19" >nul 2>&1
if %errorlevel% neq 0 goto notadmin

:: ---- is WSL present at all? ---------------------------------------------------
where wsl.exe >nul 2>&1
if %errorlevel% neq 0 goto installwsl
wsl.exe --status >nul 2>&1
if %errorlevel% neq 0 goto installwsl
goto havewsl

:installwsl
echo   [1/3] Installing WSL. This is a Windows feature, so it needs a restart.
echo.
wsl.exe --update
if %errorlevel% neq 0 goto wslupdatefailed
wsl.exe --install --no-distribution
if %errorlevel% neq 0 goto wslfeaturefailed
echo.
echo   ------------------------------------------------------------------
echo   RESTART YOUR COMPUTER NOW.
echo.
echo   After it restarts, run this same file again ^(right-click, Run as
echo   administrator^) and it will carry on from here.
echo   ------------------------------------------------------------------
echo.
pause
exit /b 0

:havewsl
echo   [1/3] WSL is installed.

:: ---- does the CS193V environment exist? --------------------------------------
powershell -NoProfile -NonInteractive -Command "%PROBE%" >nul 2>&1
if %errorlevel% equ 0 goto havedistro
if %errorlevel% equ 1 goto makedistro
goto probefailed

:makedistro
echo   [2/3] Creating the %DISTRO% Linux environment.
echo.
echo         Ubuntu will ask you a few questions while it sets itself up:
echo         a username, a password to go with it, and on Ubuntu 26.04 also
echo         whether to send anonymous usage reports. Pick anything you like
echo         and write the password down -- you will need it occasionally, and
echo         it is separate from your Windows one.
echo.
echo         When it finishes you will be left at a Linux prompt ending in $.
echo         TYPE  exit  AND PRESS ENTER there to carry on with the setup.
echo.
:: cmdlint-allow: unchecked-exit -- the exit code here is the launched shell's, not
:: the install's, so it is meaningless. The probe below is the real check.
wsl.exe --install -d %IMAGE_NAME% --name %DISTRO%

:: Deliberately NOT `if errorlevel` here. `wsl --install` launches the new environment
:: unless given --no-launch, and then returns THE LAUNCHED SHELL'S exit code -- so a
:: student who mistypes a command before `exit` looks like a failed install, and a real
:: failure returns -1 which `if errorlevel 1` cannot see. Re-running the probe asks the
:: only question that matters: is the environment there now?
::
:: --no-launch is not the fix. It skips Ubuntu's first-run setup, which leaves the default
:: user as root, so stage 2 would install into /root and the student's own account would be
:: created later with none of it.
powershell -NoProfile -NonInteractive -Command "%PROBE%" >nul 2>&1
if %errorlevel% equ 0 goto havedistro
goto distrofailed

:havedistro
echo   [2/3] The %DISTRO% environment is ready.

:: ---- hand over to the real installer ----------------------------------------
if not exist "%HERE%install-cs193v.sh" goto nosibling

echo   [3/3] Setting up the container inside %DISTRO%.
echo.

:: Translate the Windows path to the Linux path WSL sees.
::
:: VIA A FILE, not a `for /f` backtick, and the reason is a defect rather than a preference:
:: a backtick runs the command through a nested cmd /c and keeps only its STDOUT, DISCARDING
:: the exit code. And wsl.exe writes its errors to stdout, not stderr -- so a failure arrives
:: looking exactly like an answer, and "There is no distribution with the supplied name."
:: gets handed to bash as a filename. Redirecting instead means %errorlevel% is still there
:: to be asked, which is the actual question. It also avoids the double parsing a nested
:: cmd /c imposes on every caret and quote in the command line.
set "PATHFILE=%TEMP%\cs193v-linuxpath.txt"

:: Prove the scratch file can be written BEFORE using it. Otherwise an unset or unwritable
:: %TEMP% surfaces as "could not work out where CS193V sees this folder", which blames WSL
:: for something WSL had no part in -- the same mistake as treating a failed probe as a
:: negative answer.
break > "%PATHFILE%" 2>nul
if not exist "%PATHFILE%" goto noscratch

wsl.exe -d %DISTRO% -e wslpath -a "%HERE%install-cs193v.sh" > "%PATHFILE%"
if %errorlevel% neq 0 goto nopath
set "LINUXPATH="
for /f "usebackq delims=" %%i in ("%PATHFILE%") do set "LINUXPATH=%%i"
del "%PATHFILE%" >nul 2>&1
if not defined LINUXPATH goto nopath

:: Belt and braces. A real answer is an absolute Linux path, so if wsl.exe ever exits 0
:: while printing prose, this still refuses to hand it to bash.
if not "%LINUXPATH:~0,1%"=="/" goto nopath

wsl.exe -d %DISTRO% -e bash "%LINUXPATH%"
set "RC=%errorlevel%"

echo.
:: A string compare, not `if errorlevel`: stage 2 can exit -1, which prints as 4294967295
:: and is a failure, but is NOT caught by a `>=` test.
if not "%RC%"=="0" goto stage2failed

echo   ------------------------------------------------------------------
echo   Done. From now on you work inside the %DISTRO% environment:
echo.
echo       wsl -d %DISTRO%
echo       cd ~/cs193v
echo       ./cs193v
echo.
echo   You can also open %DISTRO% from the Windows Terminal dropdown.
echo   Your project files are reachable from Windows at:
echo       \\wsl.localhost\%DISTRO%\home\[your-linux-username]\cs193v\projects
echo   ------------------------------------------------------------------
echo.
pause
exit /b 0

:notadmin
echo   This needs to run as Administrator, because installing WSL is a
echo   Windows feature change.
echo.
echo   Close this window, then RIGHT-CLICK install-cs193v-windows.cmd and
echo   choose "Run as administrator".
echo.
pause
exit /b 1

:wslupdatefailed
echo.
echo   Could not update WSL.
echo.
echo   Please send course staff this whole window, and do not spend time
echo   troubleshooting it.
echo.
pause
exit /b 1

:wslfeaturefailed
echo.
echo   Could not turn on the WSL Windows feature.
echo.
echo   The usual cause is that virtualisation is switched off in your
echo   computer's firmware settings. Please send course staff this whole
echo   window, and do not spend time troubleshooting it.
echo.
pause
exit /b 1

:probefailed
echo.
echo   Could not ask WSL which environments exist.
echo.
echo   This is not the same as not having the %DISTRO% environment -- the
echo   question itself failed, so setup is stopping rather than guessing.
echo   Please send course staff this whole window.
echo.
pause
exit /b 1

:distrofailed
echo.
echo   Could not create the %DISTRO% environment.
echo.
echo   Naming a new environment needs WSL 2.5.8 or newer.
echo   Please send course staff the output of:   wsl --version
echo   and do not spend time troubleshooting this.
echo.
pause
exit /b 1

:nosibling
echo.
echo   Could not find install-cs193v.sh next to this file.
echo.
echo   Both files need to be in the same folder - download install-cs193v.sh
echo   into this one and run this again:
echo       "%HERE%"
echo.
pause
exit /b 1

:noscratch
echo.
echo   Could not create a temporary file, so setup cannot continue.
echo.
echo   Windows normally provides one; if TEMP is unset or points somewhere
echo   unwritable this is what happens. Please send course staff this whole
echo   window and the output of:   echo %%TEMP%%
echo.
pause
exit /b 1

:nopath
echo.
echo   Could not work out where %DISTRO% sees this folder.
echo   Please send this whole window to course staff.
echo.
pause
exit /b 1

:stage2failed
echo   Setup did not finish - see the messages above.
echo   It is safe to run this file again once the problem is fixed.
echo.
pause
exit /b %RC%

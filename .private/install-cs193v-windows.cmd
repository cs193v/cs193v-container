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
:: Stage 2 (auto) : DOWNLOAD install-cs193v.sh into it and run it -- the same script macOS
::                  and Linux use
::
:: ---------------------------------------------------------------------------------
:: THE ONLY THING THIS FILE FETCHES is stage 2, from INSTALLER_URL below:
::
::   https://raw.githubusercontent.com/cs193v/cs193v-container/main/.private/install-cs193v.sh
::
:: Reading this file therefore tells you everything that will run on your computer. Stage 2 is
:: fetched over HTTPS INSIDE the CS193V environment, checked for a sentinel line before it is
:: run, and left at /tmp/install-cs193v.sh in there so you can read it afterwards.
::
:: It used to be a file you had to download YOURSELF and leave next to this one. That is gone:
:: two downloads meant two things to get right, and the one that went wrong silently was a
:: stale copy from an earlier quarter, which looks like a working install and is not.
::
:: Nothing is downloaded onto Windows itself. One consequence worth knowing, since the note
:: above about the mark-of-the-web is what makes this a .cmd: that mark is an NTFS alternate
:: data stream, and stage 2 lands on the environment's own Linux filesystem, so it can never
:: carry one. THIS file still does, and still just runs, which is the whole point.
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
:: NOTHING PASSED TO wsl.exe NEEDS QUOTING, and that is asserted rather than hoped for.
:: %~dp0 used to be read into %HERE% and handed to wslpath, so a student downloading into
:: "cs193v (1)" -- what a browser names a second copy -- made an unquoted use a syntax error.
:: Stage 2 no longer comes from that folder, so the only values crossing into Linux are the
:: staff constants below, and 25-installer.sh pins them to characters that need no quotes at
:: all. That is strictly stronger than quoting: a quote has to survive cmd AND wsl.exe.
:: ---------------------------------------------------------------------------------

set "DISTRO=CS193V"
set "IMAGE_NAME=Ubuntu-26.04"

:: Where stage 2 comes from. These three MUST match install-cs193v.sh's own REPO_OWNER,
:: REPO_NAME and REPO_BRANCH; 25-installer.sh asserts that they do, because a mismatch would
:: quietly fetch the wrong course's installer and nothing would notice until it ran. A TA
:: testing a branch edits REPO_BRANCH here and nothing else.
set "REPO_OWNER=cs193v"
set "REPO_NAME=cs193v-container"
set "REPO_BRANCH=main"
set "INSTALLER_URL=https://raw.githubusercontent.com/%REPO_OWNER%/%REPO_NAME%/%REPO_BRANCH%/.private/install-cs193v.sh"

:: A LINUX path, not a Windows one: everything it names happens inside %DISTRO%. Left in place
:: on purpose after the install, so a student who wanted to read what ran still can.
set "STAGE2=/tmp/install-cs193v.sh"

:: The last line of install-cs193v.sh. A single token ON PURPOSE, so it needs no quoting on
:: either side of the Windows/Linux boundary. 25-installer.sh pins both halves of the contract:
:: that the .sh ends with it, and that it occurs there exactly once.
set "SENTINEL=CS193V-INSTALLER-COMPLETE"

:: One probe, used twice: before creating the environment and again afterwards. Batch cannot
:: read `wsl --list` directly -- its output is UTF-16, which breaks findstr and for /f alike --
:: so WSL_UTF8 makes it plain text and PowerShell does the comparison. The answer comes back
:: as an EXIT CODE rather than on stdout: 0 = present, 1 = absent, anything else = the probe
:: itself could not run, which is a different thing from "absent" and is handled separately.
set "PROBE=$env:WSL_UTF8=1; if ((wsl.exe -l -q) -match '^%DISTRO%$') { exit 0 } else { exit 1 }"

:: THREE MORE PROBES, ALL ON THE SAME CONTRACT: can this computer run a virtual machine at all?
::
:: WHY ASKING IS NECESSARY, and why `wsl --status` above cannot answer it. Status() prints the
:: default distro, the default version, a line if the WSL optional component is missing and a line
:: if vmcompute is missing -- then `return 0` UNCONDITIONALLY (WslClient.cpp:1179-1209). So a
:: machine with no Virtual Machine Platform SAYS SO on stdout and still exits zero, and the
:: `wsl.exe --status >nul` above throws that stdout away. Issue #112: the .cmd said "WSL is
:: installed", spent 600 MB downloading Ubuntu, failed at CreateVm, and blamed the WSL version.
::
:: HypervisorPresent IS THE OUTCOME QUESTION -- did a hypervisor actually load -- and it is false
:: for every cause: firmware virtualisation off, a Windows guest with no nested virtualisation, or
:: a boot configuration that does not start one. `Win32_Processor.VirtualizationFirmwareEnabled`
:: is deliberately NOT used: once a hypervisor is running it commonly reads False or null, so it
:: is only meaningful in the state where the answer is already known.
set "VIRTPROBE=if ((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) { exit 0 } else { exit 1 }"

:: ...and if no hypervisor loaded, WHICH cause, because exactly one of them is ours to fix.
::
:: Get-WindowsOptionalFeature rather than Win32_OptionalFeature -- which is what wsl.exe itself
:: queries -- only because the latter needs a -Filter containing nested double quotes, and a value
:: that has to survive `set "..."` AND cmd's parser should need neither. If the feature name is
:: ever unknown this throws and powershell exits 1, which lands on the enable arm: that runs
:: `wsl --install --no-distribution`, whose own detection is authoritative, so the wrong guess
:: here has the right consequence.
set "VMPPROBE=if ((Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State -eq 'Enabled') { exit 0 } else { exit 1 }"

:: The boot configuration. `hypervisorlaunchtype Off` means Windows never starts its hypervisor
:: however many features are enabled, which is what "disable VBS to gain FPS" advice and some
:: third-party hypervisor installers leave behind.
::
:: THE EMPTY-OUTPUT ARM IS NOT OPTIONAL. bcdedit prints nothing when it cannot read the store, and
:: a bare `-match` on nothing is FALSE -- which would report "not Off" for a question that failed.
:: Exit 2 is neither yes nor no, and the caller has an arm for it. Same rule as %PROBE%.
set "BCDPROBE=$b = bcdedit /enum '{current}'; if (-not $b) { exit 2 } elseif ($b -match 'hypervisorlaunchtype +Off') { exit 1 } else { exit 0 }"

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
goto restartneeded

:havewsl
echo   [1/3] WSL is installed.

:: ---- can this computer run a virtual machine? --------------------------------
:: BEFORE the distro probe, not inside :makedistro. Creating the environment is what needs a VM,
:: so that is where issue #112 struck -- but a machine that ALREADY has the environment and has
:: since lost virtualisation falls through to the curl probe and gets told "the network is not up
:: yet inside the new environment". That is the same wrong diagnosis at a second site, and fixing
:: one arm while leaving the other is the mistake this whole change is about.
::
:: THREE STATES PER PROBE, like %PROBE%: 0 yes, 1 no, anything else means the question itself
:: failed -- which is NOT the same as the answer being no, and must not silently become "carry on".
powershell -NoProfile -NonInteractive -Command "%VIRTPROBE%" >nul 2>&1
if %errorlevel% equ 0 goto havevirt
if %errorlevel% neq 1 goto virtprobefailed

:: No hypervisor loaded. Exactly one of the three causes is ours to fix, so ask which.
powershell -NoProfile -NonInteractive -Command "%VMPPROBE%" >nul 2>&1
if %errorlevel% equ 1 goto enablevmp
if %errorlevel% neq 0 goto virtprobefailed

powershell -NoProfile -NonInteractive -Command "%BCDPROBE%" >nul 2>&1
if %errorlevel% equ 1 goto hypervisoroff
if %errorlevel% neq 0 goto virtprobefailed
goto nohypervisor

:enablevmp
:: THE ONE THE INSTALLER CAN FIX, and it costs no extra restart: `wsl --install --no-distribution`
:: runs dism for each missing component, which is the same work `wsl --install -d` would do for
:: itself -- except that when it does, it then prints a reboot notice, installs NOTHING and exits
:: ZERO, and the re-probe below reports the environment missing for a reason nothing explains.
:: So this takes no authority over the machine that the old code did not already take; it only
:: asks first, and then asks for the restart it already needed.
echo         Turning on the Virtual Machine Platform, which WSL2 needs.
echo         This is a Windows feature, so it needs a restart.
echo.
wsl.exe --update
if %errorlevel% neq 0 goto wslupdatefailed
wsl.exe --install --no-distribution
if %errorlevel% neq 0 goto wslfeaturefailed

:restartneeded
:: SHARED, because two arms reach it now -- WSL absent entirely, and the Virtual Machine Platform
:: off on a machine that has WSL. A second copy of this block is a second chance to reword one of
:: them and not the other, and the words are the whole point: the file only works if it is run again.
::
:: PLACED so that BOTH arms reach it going FORWARD -- :installwsl by `goto`, :enablevmp by falling
:: through. A backward `goto` would work; cmd rescans from the top of the file for a label. But this
:: file keeps to a subset of batch that the test suite can verify, and it has never contained one,
:: so adding the first would be a construct to argue about in exchange for nothing.
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

:havevirt
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
:: RAISED BEFORE IT IS BLAMED. `--name` needs WSL 2.5.8, and that is the one cause
:: :distrofailed below can still name -- so naming it without ever having offered the command
:: that fixes it is the same defect as issue #112 in miniature. This ran only on the arm where
:: wsl.exe was absent altogether, which is the one machine that did not need it.
::
:: cmdlint-allow: unchecked-exit -- BEST EFFORT here, unlike the :installwsl arm where it is
:: load-bearing. `wsl --update` on an already-current WSL is not contractually zero, and a
:: refusal from an optimisation would turn a working install into a failed one. If it mattered,
:: the install below fails and says so.
wsl.exe --update

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

:: ---- fetch stage two, and run it inside the environment ----------------------
:: DOWNLOADED INSIDE WSL, NOT ON WINDOWS. That is why there is no path translation, no scratch
:: file and no `for /f` capture here any more: curl runs in the environment, writes a Linux
:: path, and bash reads that same path. `-e` runs NO SHELL, so nothing on either side of the
:: boundary re-quotes anything and no pipe is needed -- which matters, because a pipe in this
:: file aborts the whole script under wine with exit 255.
::
:: It also means the download and the install both run as the student's LINUX user. This file
:: runs as Administrator; nothing it fetches is fetched with those rights.
echo   [3/3] Downloading the setup script and setting up the container inside %DISTRO%.
echo         %INSTALLER_URL%
echo.

:: Is curl there at all? The environment is Ubuntu's image, and a base Ubuntu is not entitled
:: to have curl -- .private/Containerfile installs it explicitly for exactly that reason.
:: Without this probe a missing program is reported as a network problem, which is the same
:: mistake as treating a failed question as a negative answer. Output discarded: only the exit
:: code is being asked for.
wsl.exe -d %DISTRO% -e curl --version >nul 2>&1
if %errorlevel% neq 0 goto installcurl
goto havecurl

:installcurl
:: INSTALLED, not refused. Rule one of install-cs193v.sh is that it freely sets up things it
:: created itself and never changes what was already on the computer without asking -- and this
:: environment was created by THIS FILE, minutes ago. So no consent question is owed.
::
:: `-u root`, not sudo: it needs no password, so the student is not asked for the Linux one they
:: set thirty seconds ago. ca-certificates goes in the same call because without it curl exits
:: 60, which reads as a network problem too. `env DEBIAN_FRONTEND=noninteractive` keeps apt from
:: ever waiting on a terminal, and env is a real program, so it costs no shell.
::
:: Only reached when the probe said no. `apt-get update` is a slow round trip, and this file
:: promises it is safe to run any number of times.
echo         Installing curl in %DISTRO% first, which the download needs.
echo.
wsl.exe -d %DISTRO% -u root -e apt-get update
if %errorlevel% neq 0 goto curlfailed
wsl.exe -d %DISTRO% -u root -e env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
if %errorlevel% neq 0 goto curlfailed

:: apt exiting 0 is not the same claim as "curl is on the PATH now" -- the same distinction the
:: distro probe above makes about `wsl --install`. Ask the question again rather than assume.
wsl.exe -d %DISTRO% -e curl --version >nul 2>&1
if %errorlevel% neq 0 goto curlfailed

:havecurl
:: The same flags install-cs193v.sh's own download uses, for the same reason it uses them: the
:: single likeliest thing to go wrong here is a dropped connection on dorm wifi.
::
:: NOT redirected. curl's own `curl: (6) Could not resolve host ...` belongs in the window the
:: student pastes to course staff.
wsl.exe -d %DISTRO% -e curl -fsSL --retry 10 --retry-delay 3 -o %STAGE2% %INSTALLER_URL%
if %errorlevel% neq 0 goto downloadfailed

:: THE CHECK CURL CANNOT DO. `curl -f` catches a 404, and a cut-off transfer against a served
:: Content-Length, but not a captive portal answering 200 OK with its own login page: the bytes
:: arrived, they are simply not the installer, and it is bash that would run the HTML.
:: install-cs193v.sh's own download step carries the same guard for the same reason -- there it
:: is four files that must exist, here it is the token on that script's last line, which makes
:: this a completeness check as well as an identity one.
wsl.exe -d %DISTRO% -e grep -q %SENTINEL% %STAGE2%
if %errorlevel% neq 0 goto downloadincomplete

:: %STAGE2% is left behind deliberately -- see the success message below.
::
:: One rough edge, recorded rather than coded around: if a root-owned /tmp/install-cs193v.sh is
:: already there, from someone having run `wsl -u root` by hand, curl cannot overwrite it and
:: exits 23. The download message says the file can be run again, which is true once that copy
:: is gone. `--cd ~ -e curl -O` would avoid it, at the price of another WSL flag nothing here
:: has verified.
wsl.exe -d %DISTRO% -e bash %STAGE2%
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
echo.
echo   The setup script this downloaded is still in %DISTRO%, at
echo       %STAGE2%
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

:virtprobefailed
:: The same distinction :probefailed makes, about a different question. Three probes reach here,
:: and none of them is allowed to have its failure read as "yes, carry on" -- that would put a
:: machine that cannot run a VM into a 600 MB download.
echo.
echo   Could not ask Windows whether this computer can run virtual
echo   machines.
echo.
echo   This is not the same as the answer being no -- the question itself
echo   failed, so setup is stopping rather than guessing.
echo   Please send course staff this whole window.
echo.
pause
exit /b 1

:nohypervisor
:: The Virtual Machine Platform is on, the boot configuration is fine, and no hypervisor loaded
:: anyway. Both remaining causes are BELOW Windows, so neither is something this file can change
:: -- and saying so is the whole job. Issue #112 is this machine, told to check its WSL version.
echo.
echo   Setup cannot continue, because virtualization is switched off
echo   below Windows.
echo.
echo   Windows has the Virtual Machine Platform turned on, but no
echo   hypervisor is running, so WSL2 cannot start a virtual machine.
echo   There are two usual causes, and setup cannot fix either one:
echo.
echo     * Virtualization is disabled in your computer's firmware
echo       settings. Depending on who made the computer it is called
echo       Intel VT-x, Intel Virtualization Technology, VMX, AMD-V or
echo       SVM Mode. https://aka.ms/enablevirtualization explains how
echo       to reach that setting.
echo.
echo     * This Windows is itself running inside a virtual machine, and
echo       whatever is hosting it does not pass virtualization through.
echo       That has to be turned on where that program runs, not here.
echo.
echo   Fix one of those, restart, and run this file again. Please send
echo   course staff this whole window rather than spending time on it.
echo.
pause
exit /b 1

:hypervisoroff
:: Everything is installed and the firmware is fine; Windows is simply told not to start its
:: hypervisor. One command fixes it, and setup HANDS IT OVER rather than running it -- see the
:: last paragraph, which is the reason and is addressed to the student, not to us.
echo.
echo   Setup cannot continue. This computer can run virtual machines,
echo   but Windows is set not to start its hypervisor, so WSL2 cannot
echo   start one.
echo.
echo   To turn it back on, run this in this same Administrator window:
echo.
echo       bcdedit /set hypervisorlaunchtype Auto
echo.
echo   Then restart your computer and run this file again.
echo.
echo   Setup does not run that for you on purpose. It changes how your
echo   computer starts up, and on a computer with BitLocker turned on
echo   that can ask for your recovery key at the next restart. If you
echo   do not have that key written down somewhere, ask course staff
echo   before running it.
echo.
pause
exit /b 1

:distrofailed
:: ONE LIKELY CAUSE, NAMED AS A GUESS. It used to be stated as the diagnosis, and issue #112 is
:: what that cost: a machine that could not run a virtual machine at all was sent to
:: `wsl --version`, which answered 2.9.8 and helped nobody. The pre-flight above now rules out
:: every cause it can, and `wsl --update` has already run, so what is left really is likeliest --
:: but likeliest is not the same claim, and the window is what staff actually need.
echo.
echo   Could not create the %DISTRO% environment.
echo.
echo   Setup has already checked what it can: WSL is installed, this
echo   computer can run virtual machines, and WSL has just been updated.
echo   The likeliest cause left is a WSL older than 2.5.8, which cannot
echo   name a new environment -- but that is a guess, not a diagnosis.
echo.
echo   Please send course staff this whole window, including any
echo   "Error code:" line above, and the output of:   wsl --version
echo   Do not spend time troubleshooting this.
echo.
pause
exit /b 1

:curlfailed
echo.
echo   Could not install curl in the %DISTRO% environment, which setup
echo   needs in order to download the rest of itself.
echo.
echo   The usual cause is that the network is not up yet inside the new
echo   environment. It is safe to run this file again.
echo.
echo   If it keeps happening, please send course staff this whole window
echo   and the output of:   wsl -d %DISTRO% -u root -e apt-get install curl
echo.
pause
exit /b 1

:downloadfailed
echo.
echo   Could not download the setup script from:
echo       %INSTALLER_URL%
echo.
echo   This is usually a network problem, and it is safe to run this file
echo   again. Some campus and company networks block
echo   raw.githubusercontent.com outright; if yours does, tell course staff
echo   rather than spending time on it.
echo.
pause
exit /b 1

:downloadincomplete
echo.
echo   The setup script downloaded, but it is not the whole file, so setup
echo   is stopping rather than running part of it.
echo.
echo   That means the transfer was cut short, or something on the network
echo   answered instead of the real thing - a wifi sign-in page, typically.
echo   Get properly connected and run this file again.
echo.
pause
exit /b 1

:stage2failed
echo   Setup did not finish - see the messages above.
echo   It is safe to run this file again once the problem is fixed.
echo.
pause
exit /b %RC%

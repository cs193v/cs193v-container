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
:: Stage 1 (here) : install WSL and the CS193V Linux environment, then prepare it -- switch
::                  Ubuntu's first-run questions off, create the student's account, and give it
::                  everything the install needs root for
:: Stage 2 (auto) : DOWNLOAD install-cs193v.sh into it and run it -- the same script macOS
::                  and Linux use. It runs TWICE: once as root to prepare the environment, then
::                  as the student, which is the install a Mac or Linux student sees
::
:: ---------------------------------------------------------------------------------
:: THE ONLY THING THIS FILE FETCHES is stage 2, from INSTALLER_URL below:
::
::   https://raw.githubusercontent.com/cs193v/cs193v-container/main/.private/install-cs193v.sh
::
:: Reading this file therefore tells you everything that will run on your computer. Stage 2 is
:: fetched over HTTPS INSIDE the CS193V environment, checked for a sentinel line before it is
:: run, and left at /var/tmp/install-cs193v.sh in there so you can read it afterwards.
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
::   * AN UNQUALIFIED PROGRAM NAME. cmd.exe searches the current directory BEFORE %PATH%, and
::     this file runs elevated from the student's download folder, so a bare `wsl.exe` would run
::     a copy planted there with Administrator rights. Every external program is named through
::     %SYS32%; the block just below this header holds the three lines that close it. Issue #125.
::
:: NOTHING PASSED TO wsl.exe NEEDS QUOTING, and that is asserted rather than hoped for.
:: %~dp0 used to be read into %HERE% and handed to wslpath, so a student downloading into
:: "cs193v (1)" -- what a browser names a second copy -- made an unquoted use a syntax error.
:: Stage 2 no longer comes from that folder, so the only values crossing into Linux are the
:: staff constants below, and 25-installer.sh pins them to characters that need no quotes at
:: all. That is strictly stronger than quoting: a quote has to survive cmd AND wsl.exe.
:: ---------------------------------------------------------------------------------

:: ---- where the system's own programs live ------------------------------------
:: EVERY EXTERNAL PROGRAM BELOW IS NAMED THROUGH %SYS32%, and that is issue #125 rather than a
:: style choice. This file runs elevated with the DOWNLOAD FOLDER as its working directory, and
:: cmd.exe searches the current directory BEFORE %PATH% -- so a wsl.exe sitting in Downloads is
:: what a bare `wsl.exe` runs, as Administrator. Downloads is the likeliest place on the machine
:: for an untrusted file to already be, and wsl.exe has nineteen call sites here, one of them the
:: handoff to stage two.
::
:: %SystemRoot% RATHER THAN A HARD-CODED C:\Windows, because Windows need not be installed on C:
:: and the directory need not be called Windows. System32 is never localised, so no translation
:: enters into it either.
::
:: SYSNATIVE IS FOR A 32-BIT HOST, and it is not theoretical. Measured from
:: C:\Windows\SysWOW64\cmd.exe on Windows 11 26200: %SystemRoot%\System32\wsl.exe is MISSING,
:: because WOW64 redirects System32 to SysWOW64 and wsl.exe exists only in the native one.
:: %SystemRoot%\Sysnative reaches it, and `if exist`, launching and `cd /d` all work through it.
:: PROCESSOR_ARCHITEW6432 is defined ONLY in a 32-bit process on 64-bit Windows, which is exactly
:: when that redirection applies. Without this arm the fix would not be insecure, it would be
:: broken -- a worse failure, and a harder one to attribute.
set "SYS32=%SystemRoot%\System32"
if defined PROCESSOR_ARCHITEW6432 set "SYS32=%SystemRoot%\Sysnative"

:: ---- two additive guards, and NEITHER replaces the qualification above --------
:: TURN THE CURRENT-DIRECTORY SEARCH OFF ALTOGETHER. cmd.exe consults
:: NoDefaultCurrentDirectoryInExePath -- documented since Vista -- and its EXISTENCE, not its
:: value, is what gets checked. This covers what naming a path cannot: a program name that arrives
:: through a variable, or a call site added before anyone next runs the test suite.
::
:: ORDER IS THE WHOLE CONTRACT, because it protects the commands that FOLLOW it. Measured in a
:: real .cmd on Windows 11 26200: a bare exe called before this line still resolved from the
:: current directory, the same call after it did not, and clearing the variable re-enabled the
:: search -- so cmd re-reads it per command while running a batch file. NOT so for
:: `cmd /c "a & b"`, where the search path is fixed once for the whole line; a measurement taken
:: that way makes this line look as though it does nothing. 25-installer.sh pins that it sits
:: ahead of every external call.
set "NoDefaultCurrentDirectoryInExePath=1"

:: AND LEAVE THE DOWNLOAD FOLDER. This is the only one of the three that also closes DLL planting:
:: with SafeDllSearchMode on, the current directory is searched AFTER the system directories, so a
:: DLL named like a system one cannot win -- but one that is in no system directory at all can.
::
:: %SystemRoot% AND NOT %SYS32%: C:\Windows is a real directory under both the native and the
:: WOW64 view, so it needs no reasoning about the redirector. Nothing here depends on the working
:: directory -- %~dp0, wslpath and %TEMP% are all banned, and 25-installer.sh asserts they are
:: gone -- and every value crossing into Linux is an absolute path, so the distro starting in
:: /mnt/c/windows is inert. Deliberately unchecked: `cd` is a builtin, and if it somehow failed
:: the qualification above still carries the property on its own.
cd /d "%SystemRoot%"

set "DISTRO=CS193V"
set "IMAGE_NAME=Ubuntu-26.04"

:: The Linux account this file creates inside %DISTRO%, and the ONE name it can be. It is the
:: container's own account name too (.private/Containerfile), so the same word is right inside the
:: container and outside it -- which is what lets the success message below hand a student a real
:: path instead of one with a placeholder in it. .private/wsl-provision.sh carries the same
:: constant as WSL_USER, and 25-installer.sh fails if the two disagree or if this one ever holds a
:: character that would need quoting on the way into wsl.exe.
set "LINUX_USER=student"

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
::
:: /var/tmp AND NOT /tmp, AND THAT IS A MEASUREMENT (#217). Inside a WSL instance running systemd
:: -- which %DISTRO% does -- /tmp is a TMPFS. Measured on 2026-09-10: a file written to /tmp is
:: gone after `wsl --terminate`, and this file now restarts the environment between downloading
:: this script and running it, so a copy in /tmp would not be there when bash was handed the path.
:: /var/tmp is on the environment's own disk and survives, which also makes "it is still in there
:: if you want to read it" true tomorrow rather than only until the next restart.
set "STAGE2=/var/tmp/install-cs193v.sh"

:: The last line of install-cs193v.sh. A single token ON PURPOSE, so it needs no quoting on
:: either side of the Windows/Linux boundary. 25-installer.sh pins both halves of the contract:
:: that the .sh ends with it, and that it occurs there exactly once.
set "SENTINEL=CS193V-INSTALLER-COMPLETE"

:: One probe, used twice: before creating the environment and again afterwards. Batch cannot
:: read `wsl --list` directly -- its output is UTF-16, which breaks findstr and for /f alike --
:: so WSL_UTF8 makes it plain text and PowerShell does the comparison. The answer comes back
:: as an EXIT CODE rather than on stdout: 0 = present, 1 = absent, anything else = the probe
:: itself could not run, which is a different thing from "absent" and is handled separately.
set "PROBE=$env:WSL_UTF8=1; $w=$env:SystemRoot+'\System32\wsl.exe'; if ((& $w -l -q) -match '^%DISTRO%$') { exit 0 } else { exit 1 }"

:: A SECOND PROBE, ASKED ONLY AFTER SOMETHING HAS ALREADY FAILED: does Windows itself say the
:: problem is virtualisation? `wsl --status` prints a line saying so and then returns 0
:: UNCONDITIONALLY (WslClient.cpp:1179-1209) -- which IS issue #112, because this file used to
:: send that stdout to nul and branch on the exit code. So the line is read instead of the code.
::
:: IT DECIDES WHICH REFUSAL TO PRINT, NOT WHETHER TO CONTINUE, and that is the whole reason
:: reading a message is sound here when it would not be as a pre-flight. Both callers have already
:: failed by the time they ask; a wrong answer costs a less specific refusal, not a 600 MB
:: download and not a dead end for a machine that is fine.
::
:: MATCHED ON THE URL AND NOT THE PROSE, because the prose is localised and the URL is not. It is
:: part of Microsoft's own MessageEnableVirtualization, which is also what makes this a question
:: about what wsl.exe SAID rather than another guess at a property of the machine.
::
:: TWO STATES, DELIBERATELY, where %PROBE% has three: 0 means Windows blamed virtualisation, and
:: everything else -- "it did not" and "the probe itself could not run" -- reaches the same honest
:: refusal, so splitting them would be a branch with no different behaviour behind it.
set "VMFAILPROBE=$env:WSL_UTF8=1; $w=$env:SystemRoot+'\System32\wsl.exe'; if ((& $w --status 2>&1) -match 'aka.ms/enablevirtualization') { exit 0 } else { exit 1 }"

:: THERE IS NO VIRTUALISATION PRE-FLIGHT, AND TWO OF THEM HAVE NOW BEEN REMOVED FROM HERE.
:: Anyone about to add a third should read .private/README.md first; both are recorded there with
:: the measurement that killed them. In short:
::
::   * ASKING WINDOWS A PROPERTY (issue #112's fix). Win32_ComputerSystem.HypervisorPresent, with
::     Get-WindowsOptionalFeature and bcdedit behind it to say which cause it was. #114 is a
::     VirtualBox guest where HypervisorPresent reads TRUE -- VirtualBox sets the hypervisor-
::     present CPUID bit, so a hypervisor IS there, just not one WSL2 can build a VM with. Every
::     property like it is a proxy with its own blind spot.
::   * OBSERVING A THROWAWAY IMPORT (issue #114's fix). `wsl --import` of a 1.5 KB tarball of an
::     empty directory, then "is it registered now". Measured: `--import` validates the rootfs at
::     RegisterDistro, so an empty one is refused as WSL_E_NOT_A_LINUX_DISTRO on EVERY machine --
::     including one with a VM running. It answered "no VM" for the entire class.
::
:: WHAT REPLACES THEM IS NOTHING, because the failure already announces itself. `wsl --install -d`
:: below is not redirected, so on a machine that cannot start a VM the student's window already
:: holds wsl.exe's own words and its HCS_E_HYPERV_NOT_INSTALLED scope chain. #112 was never a
:: missing observation; it was this file printing a DIFFERENT cause over the top of a correct one.
:: So the diagnosis moved to the two places that fail, and neither of them guesses any more.

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
:: language, and it works from a 32-bit process: reg.exe exists in both System32 and SysWOW64,
:: and %SYS32% names whichever of the two is the native one. It also succeeds for SYSTEM, so a
:: management agent running this is not locked out.
::
:: The `whoami /groups | findstr S-1-16-12288` form reads the integrity level directly and is
:: the more precise test, but it needs a PIPE. In batch a pipe runs each side in a child cmd,
:: which loses the calling script context and is a well-known source of quoting surprises --
:: so avoiding one for a question a single command can answer is the better trade regardless.
:: Corroborated the hard way: under wine that pipe does not merely misbehave, it aborts the
:: whole script with exit 255, which is also why no test could have covered it.
"%SYS32%\reg.exe" query "HKU\S-1-5-19" >nul 2>&1
if %errorlevel% neq 0 goto notadmin

:: ---- is WSL present at all? ---------------------------------------------------
if not exist "%SYS32%\wsl.exe" goto installwsl
"%SYS32%\wsl.exe" --status >nul 2>&1
if %errorlevel% neq 0 goto installwsl
goto havewsl

:installwsl
echo   [1/3] Installing WSL. This is a Windows feature, so it needs a restart.
echo.
"%SYS32%\wsl.exe" --update
if %errorlevel% neq 0 goto wslupdatefailed
"%SYS32%\wsl.exe" --install --no-distribution
if %errorlevel% neq 0 goto wslfeaturefailed
goto restartneeded

:restartneeded
:: ONE CALLER -- WSL absent entirely.
::
:: PLACED so that caller reaches it going FORWARD. A backward `goto` would work; cmd rescans from
:: the top of the file for a label. But this file keeps to a subset of batch that the test suite
:: can verify, and it has never contained one, so adding the first would be a construct to argue
:: about in exchange for nothing.
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
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PROBE%" >nul 2>&1
if %errorlevel% equ 0 goto havedistro
if %errorlevel% equ 1 goto makedistro
goto probefailed

:makedistro
echo   [2/3] Creating the %DISTRO% Linux environment.
echo.
echo         There is nothing for you to type while this happens. It takes
echo         about a minute, and it may go quiet for a while in the middle
echo         -- that is setup preparing the environment, not a hang.
echo.
:: RAISED BEFORE IT IS BLAMED. `--name` needs WSL 2.4.4, and that is the one cause
:: :distrofailed below can still name -- so naming it without ever having offered the command
:: that fixes it is the same defect as issue #112 in miniature. This ran only on the arm where
:: wsl.exe was absent altogether, which is the one machine that did not need it.
::
:: cmdlint-allow: unchecked-exit -- BEST EFFORT here, unlike the :installwsl arm where it is
:: load-bearing. `wsl --update` on an already-current WSL is not contractually zero, and a
:: refusal from an optimisation would turn a working install into a failed one. If it mattered,
:: the install below fails and says so.
"%SYS32%\wsl.exe" --update

:: --no-launch, AND THE COMMENT HERE USED TO SAY THE OPPOSITE (#217). It said --no-launch was not
:: the fix, because it skips Ubuntu's first-run setup, which leaves the default user as root, so
:: stage 2 would install into /root. That is true only if nothing creates a user in between --
:: and creating one is exactly what the provisioning pass below does, out of the installer's own
:: code, with no password for a student to invent and no questions for them to answer.
::
:: AND THE EXIT CODE MEANS SOMETHING NOW, which is why this one is checked where it was not
:: before. Without --no-launch, `wsl --install` LAUNCHES the new environment and returns THE
:: LAUNCHED SHELL'S code -- so a student who mistyped a command before `exit` looked exactly like
:: a failed install. With it there is no shell in the picture and the code is the install's own.
"%SYS32%\wsl.exe" --install -d %IMAGE_NAME% --name %DISTRO% --no-launch
if %errorlevel% neq 0 goto distrofailed

:: AND THE PROBE STAYS, because a zero exit still does not mean the environment exists: when a
:: Windows component had to be enabled, wsl.exe prints the reboot notice, installs NOTHING and
:: returns 0. That is issue #112's mechanism. The two checks answer different questions and both
:: are asked.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PROBE%" >nul 2>&1
if %errorlevel% neq 0 goto distrofailed

:: UBUNTU'S FIRST-RUN QUESTIONS OFF, IMMEDIATELY, BEFORE ANYTHING ELSE. --install has already
:: created the Start Menu entry and the Windows Terminal profile, so from the moment it returns
:: there is a clickable CS193V with no account in it -- and for as long as the first-run setup is
:: armed, clicking it starts asking a student for a username and a password. Worse than the
:: confusion: the next `wsl -d` call this file makes would then block waiting for them to finish,
:: on an event with no timeout.
::
:: `mv` AND NOT `truncate -s 0`. truncate CREATES the file when it is absent and exits 0, so the
:: day Ubuntu keeps that configuration somewhere else, truncate would report success and leave the
:: questions armed. mv fails, and :provisionfailed says so. It is also reversible, and it explains
:: itself to anyone reading /etc later.
::
:: ONLY ON THIS ARM. An environment that already existed may have had this done to it already, and
:: `mv` fails on a source that is not there -- so the provisioning pass ensures it instead, where
:: a shell can tell "already off" from "not there at all".
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e mv /etc/wsl-distribution.conf /etc/wsl-distribution.conf.cs193v
if %errorlevel% neq 0 goto provisionfailed

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
"%SYS32%\wsl.exe" -d %DISTRO% -e curl --version >nul 2>&1
if %errorlevel% neq 0 goto installcurl
goto havecurl

:installcurl
:: INSTALLED, not refused. Rule one of install-cs193v.sh is that it freely sets up things it
:: created itself and never changes what was already on the computer without asking -- and this
:: environment was created by THIS FILE, minutes ago. So no consent question is owed.
::
:: `-u root`, not sudo: this runs before the account exists at all, and the account it will
:: create has a locked password (#217), so sudo could never have answered here. ca-certificates
:: goes in the same call because without it curl exits 60, which reads as a network problem too.
:: `env DEBIAN_FRONTEND=noninteractive` keeps apt from ever waiting on a terminal, and env is a
:: real program, so it costs no shell.
::
:: Only reached when the probe said no. `apt-get update` is a slow round trip, and this file
:: promises it is safe to run any number of times.
echo         Installing curl in %DISTRO% first, which the download needs.
echo.
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e apt-get update
if %errorlevel% neq 0 goto curlfailed
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
if %errorlevel% neq 0 goto curlfailed

:: apt exiting 0 is not the same claim as "curl is on the PATH now" -- the same distinction the
:: distro probe above makes about `wsl --install`. Ask the question again rather than assume.
"%SYS32%\wsl.exe" -d %DISTRO% -e curl --version >nul 2>&1
if %errorlevel% neq 0 goto curlfailed

:havecurl
:: The same flags install-cs193v.sh's own download uses, for the same reason it uses them: the
:: single likeliest thing to go wrong here is a dropped connection on dorm wifi.
::
:: NOT redirected. curl's own `curl: (6) Could not resolve host ...` belongs in the window the
:: student pastes to course staff.
::
:: `-u root`, AND IT IS LOAD-BEARING NOW RATHER THAN BELT-AND-BRACES (#217). On a FIRST run the
:: default user is root anyway, because --no-launch leaves it that way. On every run after that
:: the environment starts as %LINUX_USER% -- and %STAGE2% is a root-owned file from the first run,
:: which a non-root curl cannot overwrite: it exits 23 and this file would refuse a re-run it
:: promises is safe. Downloading as root keeps one owner for the file forever. Mode 644, so the
:: student's own pass can still read it.
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e curl -fsSL --retry 10 --retry-delay 3 -o %STAGE2% %INSTALLER_URL%
if %errorlevel% neq 0 goto downloadfailed

:: THE CHECK CURL CANNOT DO. `curl -f` catches a 404, and a cut-off transfer against a served
:: Content-Length, but not a captive portal answering 200 OK with its own login page: the bytes
:: arrived, they are simply not the installer, and it is bash that would run the HTML.
:: install-cs193v.sh's own download step carries the same guard for the same reason -- there it
:: is four files that must exist, here it is the token on that script's last line, which makes
:: this a completeness check as well as an identity one.
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e grep -q %SENTINEL% %STAGE2%
if %errorlevel% neq 0 goto downloadincomplete

:: ---- who is already in this environment decides what may be done to it ------
:: TWO PROBES, THREE STATES EACH, and the same idiom %PROBE% uses: 0 is yes, 2 is no, and
:: anything else means the QUESTION failed, which is not the same as a negative answer. getent's
:: codes are exactly that clean -- measured on 2026-09-10: 0 for an account that exists, 2 for one
:: that does not.
::
:: FIRST: is the account ours? If it is, this environment was set up by this file, and the
:: provisioning pass below is free to run again -- every step it takes checks first, so a second
:: run costs a few probes and finishes anything the first one did not. There is deliberately NO
:: "the account exists, so skip it" short cut: a run that created the account and then failed at
:: the package install would jump straight to the student's pass, which would reach `sudo` on an
:: account whose password is locked. That is the one failure this whole arrangement prevents.
:: OUTPUT DISCARDED, ONLY THE CODE IS BEING ASKED FOR -- the same treatment the curl probe above
:: gets, and for a sharper reason here: `getent passwd` PRINTS the account's whole entry, and a
:: raw /etc/passwd line in the middle of a refusal is noise a student cannot use.
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e getent passwd %LINUX_USER% >nul 2>&1
if %errorlevel% equ 0 goto provision
if %errorlevel% neq 2 goto provisionfailed

:: SECOND: is somebody ELSE in here? Almost always a CS193V created by an earlier version of this
:: installer, which asked the student to invent a username -- so their work is in it, under a
:: different home directory. Creating a second account would change which one they land in and
:: where their files live, silently, and this file has no way to ask: it is non-interactive apart
:: from `pause`. So it refuses and names the one command that resolves it.
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e getent passwd 1000 >nul 2>&1
if %errorlevel% equ 0 goto foreignaccount
if %errorlevel% neq 2 goto provisionfailed

:provision
:: THE ROOT PASS. Same script, same download, one environment variable -- so nothing new is
:: fetched and nothing new is trusted. It switches Ubuntu's first-run questions off if that has
:: not happened yet, creates %LINUX_USER% with NO password, records it in /etc/wsl.conf as the
:: account this environment starts in, and runs every step of the install that needs root out of
:: the installer's own list of them.
::
:: `-u root` EXPLICITLY, not relying on the default. On a first run the default user is root and
:: this is redundant; on a re-run it is not, because by then /etc/wsl.conf names %LINUX_USER% --
:: and a run resuming after a failure could be in either state. Being explicit costs nothing and
:: makes this call mean the same thing every time.
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e env CS193V_PROVISION=1 bash %STAGE2%
if %errorlevel% neq 0 goto provisionfailed

:: AND THE ENVIRONMENT HAS TO BE RESTARTED BEFORE ANY OF THAT COUNTS. /etc/wsl.conf is read when
:: an instance STARTS, and an idle one lingers for fifteen seconds -- so consecutive wsl.exe calls
:: from a batch file reuse the instance AND the configuration it booted with. Without this, the
:: pass below would run as root and install into /root. It is the trap that silently breaks every
:: obvious alternative to this sequence.
"%SYS32%\wsl.exe" --terminate %DISTRO%
if %errorlevel% neq 0 goto provisionfailed

:: THE HANDOVER, ASKED RATHER THAN ASSUMED -- the same standard as the curl re-probe above. "Is
:: /home/%LINUX_USER% owned by the user I am running as?" is the one question whose answer needs
:: the account to exist, /etc/wsl.conf to name it, and the restart to have happened. It needs no
:: capture, no pipe and no quoting.
"%SYS32%\wsl.exe" -d %DISTRO% -e test -O /home/%LINUX_USER%
if %errorlevel% neq 0 goto provisionfailed

:: %STAGE2% IS LEFT BEHIND, and nothing here removes it. The closing message used to name
:: it; that message moved into the installer's own catalogue (#218) and dropped the line,
:: because a student has no second use for this copy. It is root-owned and world-readable,
:: which is why the call below can read it as %LINUX_USER% without being root itself.

:: CS193V_WINDOWS IS WHY THERE IS ONE CLOSING MESSAGE AND NOT TWO (#218). A block of
:: instructions used to be echoed from here after this call returned -- straight after the
:: UNIX sign-off course-install.sh had already printed inside WSL. Two closing messages,
:: disagreeing, and the first of them wrong because it omits the `wsl -d` step entirely.
:: The variable makes course-install.sh print the Windows sign-off INSTEAD of the UNIX one,
:: which also fixes the half this file could never have got right: it hardcoded ~/cs193v and
:: a UNC path under home/%LINUX_USER%, and choose_dir lets a student install anywhere.
::
:: env, AND ONE BARE TOKEN, exactly as the root pass above passes CS193V_PROVISION. Nothing
:: passed to wsl.exe needs quoting and 25-installer.sh asserts that, so the value stays 1.
"%SYS32%\wsl.exe" -d %DISTRO% -e env CS193V_WINDOWS=1 bash %STAGE2%
set "RC=%errorlevel%"

echo.
:: A string compare, not `if errorlevel`: stage 2 can exit -1, which prints as 4294967295
:: and is a failure, but is NOT caught by a `>=` test.
if not "%RC%"=="0" goto stage2failed
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
:: ASK WINDOWS WHY BEFORE SAYING ANYTHING OF OUR OWN. See %VMFAILPROBE% above for why reading
:: wsl.exe's message is sound at this point and would not be as a pre-flight; a miss falls through
:: to the honest refusal below.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%VMFAILPROBE%" >nul 2>&1
if %errorlevel% equ 0 goto novm

:: ONE LIKELY CAUSE, NAMED AS A GUESS -- and reached only when nothing said otherwise. It used to
:: be stated as the diagnosis, and issue #112 is what that cost: a machine that could not run a
:: virtual machine at all was sent to `wsl --version`, which answered 2.9.8 and helped nobody.
::
:: WHAT THIS NO LONGER CLAIMS. It used to open by asserting that this computer can run virtual
:: machines, on the strength of a pre-flight that had just said so. Both pre-flights this file has
:: had were wrong about that -- see the header -- and the sentence was doing real damage in the
:: meantime, because it contradicted an accurate error printed a few lines above it. Setup asserts
:: only what it actually did: WSL is present, and `wsl --update` has run.
echo.
echo   Could not create the %DISTRO% environment.
echo.
echo   Setup has checked what it can: WSL is installed, and WSL has
echo   just been updated. The likeliest cause left is a WSL older than
echo   2.4.4, which cannot name a new environment -- but that is a
echo   guess, not a diagnosis, and any error above is worth more.
echo.
echo   Please send course staff this whole window, including any
echo   "Error code:" line above, and the output of:   wsl --version
echo   Do not spend time troubleshooting this.
echo.
pause
exit /b 1

:curlfailed
:: THE SECOND SITE THAT NEEDS A VM, and the one #112's fix never reached. Every `wsl -d` call
:: needs the utility VM, so a machine that has the environment but has lost virtualisation fails
:: here rather than at the create -- and this block used to state the network as the cause and
:: then invite a re-run, which on that machine is a loop with no exit. Same classifier, same
:: shared refusal.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%VMFAILPROBE%" >nul 2>&1
if %errorlevel% equ 0 goto novm

:: NOT STATED AS THE CAUSE ANY MORE. The network really is the likeliest thing when the
:: environment is otherwise healthy, so it is still named -- as a possibility, with the retry
:: attached to it rather than to every reason this block can be reached.
echo.
echo   Could not install curl in the %DISTRO% environment, which setup
echo   needs in order to download the rest of itself.
echo.
echo   If the network was not up yet inside the environment, running
echo   this file again is enough. If it happens twice, it is something
echo   else and running it a third time will not help.
echo.
echo   Please send course staff this whole window, including any
echo   "Error code:" line above, and the output of:
echo       wsl -d %DISTRO% -u root -e apt-get install curl
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

:provisionfailed
:: THE THIRD SITE THAT NEEDS THE UTILITY VM, and it opens the same way :curlfailed does. Every
:: `wsl -d` call needs one, so a machine that has the environment and has lost virtualisation
:: fails here -- at the create, at the curl, or in this block, and #114's lesson is that a second
:: site needs the same classifier rather than a guess of its own.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%VMFAILPROBE%" >nul 2>&1
if %errorlevel% equ 0 goto novm

:: AND IT IS NOT :distrofailed, deliberately. That block names one cause -- a WSL too old to name
:: an environment -- which has nothing to do with preparing one that already exists. Sending this
:: failure there would print a wrong cause over a correct message, which is #112's whole anatomy.
echo.
echo   Could not prepare the %DISTRO% environment.
echo.
echo   The %DISTRO% environment exists, but setup could not finish
echo   getting it ready: creating your Linux account in it, or
echo   installing what the course needs there.
echo.
echo   It is safe to run this file again once the problem above is
echo   fixed -- each step checks whether it has already been done.
echo.
echo   Please send course staff this whole window, including any
echo   "Error code:" line above.
echo.
pause
exit /b 1

:foreignaccount
:: NOT A MUTATION, AND NOT A SILENT ONE EITHER. There is an account in this environment that this
:: installer did not create -- almost always a CS193V from an earlier quarter, where Ubuntu's
:: first-run setup asked the student to choose a username. Their work is in it. Creating a second
:: account would change which account the environment starts in and where their home directory
:: is, without asking, and this file cannot ask: it is non-interactive apart from `pause`.
::
:: SO IT NAMES THE COMMAND AND WHAT THE COMMAND COSTS. `wsl --unregister` deletes the environment
:: and everything saved inside it. Anything on the Windows drives is untouched, because those are
:: mounted rather than stored in there -- worth saying, because it is the difference between a
:: student running it calmly and not running it at all.
echo.
echo   The %DISTRO% environment already has a Linux account in it that
echo   this installer did not create, so setup has stopped rather than
echo   adding a second one.
echo.
echo   That normally means %DISTRO% was set up by an earlier version of
echo   this installer, which asked you to choose a username. To let this
echo   version set it up from scratch, remove it and run this file again:
echo.
echo       wsl --unregister %DISTRO%
echo.
echo   THAT DELETES EVERYTHING INSIDE THE %DISTRO% ENVIRONMENT, including
echo   any work saved in there. Files on your Windows drives are not
echo   affected. If you are not sure, ask course staff first.
echo.
pause
exit /b 1

:stage2failed
echo   Setup did not finish - see the messages above.
echo   It is safe to run this file again once the problem is fixed.
echo.
pause
exit /b %RC%

:novm
:: ONE REFUSAL, SHARED BY ALL THREE SITES THAT NEED A VM -- creating an environment, preparing
:: one, and using one that already exists. Reached only when wsl.exe has ALREADY SAID that
:: virtualisation is the problem, so this block deliberately explains nothing: repeating the
:: cause in our own words is what turned #112 from a clear error into a wrong one.
::
:: IT HANDS OVER NO COMMANDS OF ITS OWN, and it no longer needs to. Enabling the Virtual Machine
:: Platform used to be offered from an arm here, decided by a probe that had to be kept in step
:: with reality -- and #114 is that probe being wrong. wsl.exe's own message names the firmware
:: and the optional component, hands over `wsl.exe --install --no-distribution`, and links
:: aka.ms/enablevirtualization, all of it a few lines above this one. Microsoft maintains that
:: text; we do not have to.
echo.
echo   Setup cannot continue: Windows could not start a virtual
echo   machine, which is what WSL2 needs.
echo.
echo   The messages above are from Windows itself and say what is
echo   wrong with this computer. Setup is not going to guess at a
echo   different reason.
echo.
echo   Please send course staff this whole window. Do not spend time
echo   troubleshooting this yourself, and do not run this file again
echo   until it has been sorted out.
echo.
pause
exit /b 1

@echo off
setlocal
::
:: CS193V setup for Windows -- stage one.
::
:: HOW TO RUN THIS: run it as yourself. Do NOT "Run as administrator" -- see below.
::
:: DO NOT RUN THIS AS AN ADMINISTRATOR, and that reverses what this line used to say. Nearly
:: everything here is PER-USER: %APPDATA%, %LOCALAPPDATA% and HKCU -- which is where WSL registers
:: environments, there being no machine-wide registration -- all follow the token the process runs
:: under. A student who is not an administrator cannot be elevated as THEMSELVES: UAC asks for
:: somebody else's password and the whole file then runs as that account, which silently installs
:: the course into THAT account's profile and leaves the student's with nothing. Measured on
:: Windows 11 26200 on 2026-09-15. The one step that genuinely needs an administrator is turning
:: WSL on, and :installwsl asks for permission for that step by itself.
::
:: A .cmd file is used rather than a .ps1 on purpose, and the difference is what each mark costs.
:: A downloaded .ps1 is REFUSED outright under the default execution policy -- unsigned and of
:: internet origin -- and clearing that needs Unblock-File or -ExecutionPolicy Bypass, which
:: teaches students to click past security warnings in a course about not trusting code. A .ps1
:: also has no execute association at all, so nothing happens when you double-click one.
:: Where batch is a poor tool, this shells out to short PowerShell commands.
::
:: THE MARK OF THE WEB REACHES A .cmd TOO, which this header used to deny -- "a .cmd just runs".
:: Measured 2026-09-15: a copy downloaded from a browser carries a Zone.Identifier stream
:: [ZoneTransfer] ZoneId=3, and Windows then refuses to run it from a double-click. The difference
:: from a .ps1 is that it is the Attachment Manager rather than a policy, so launching the file by
:: its full path runs it -- there is nothing to unblock and nothing to teach anyone to override.
:: The course instructions carry the gesture; nothing in this file depends on which one is used,
:: and no message here names one.
::
:: RUN IT AS YOURSELF, BOTH TIMES. If WSL is not installed yet this takes two runs, because
:: turning on a Windows feature needs a restart: the first run asks Windows for permission for
:: that one step -- one UAC prompt, mid-run -- and then says to restart; the second finishes the
:: job. If WSL is already on, one run does everything and nothing asks for permission at all.
:: It is safe to run any number of times.
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
:: Nothing is DOWNLOADED onto Windows itself. One consequence worth knowing, since the note
:: above about the mark-of-the-web is what makes this a .cmd: that mark is an NTFS alternate
:: data stream, and stage 2 lands on the environment's own Linux filesystem, so it can never
:: carry one. THIS file still does -- and, per the measurement above, is refused from a
:: double-click because of it.
::
:: TWO FILES ARE WRITTEN TO THE WINDOWS SIDE, AND UNTIL #134 THERE WERE NONE. The paragraph
:: above used to read "nothing is downloaded onto Windows itself" and was taken to mean this
:: file touches nothing out there at all, which is no longer true. The Start Menu section near
:: the end creates
::
::     %APPDATA%\Microsoft\Windows\Start Menu\Programs\CS193V Development Environment.lnk
::     %LOCALAPPDATA%\CS193V\cs193v.ico
::
:: and deletes the Start Menu entry `wsl --install` made. Neither is downloaded -- the icon is
:: copied out of the environment over \\wsl.localhost, so the mark-of-the-web argument above
:: still holds for both.
::
:: THEY ARE PER-USER, AND THE QUESTION THAT MATTERS IS *WHICH* USER. This paragraph used to end
:: "both are per-user and need no elevation of their own", which is true about permissions and
:: silent about identity -- and that silence is the whole of the cross-account defect. %APPDATA%
:: and %LOCALAPPDATA% name the profile of the account THIS FILE IS RUNNING AS, which under an
:: over-the-shoulder elevation is the administrator's and not the student's. There is no way to
:: write into another profile from here and no attempt to: what makes that account the right one
:: is :isadmin, which refuses an elevated run outright. If that refusal is ever relaxed into a
:: conditional, every path below silently comes to belong to whoever answered the UAC prompt.
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
::     this file runs from the student's download folder, so a bare `wsl.exe` would run a copy
::     planted there. Every external program is named through %SYS32%; the block just below this
::     header holds the three lines that close it. Issue #125. It said "with Administrator rights"
::     while this file required elevation; it refuses that now, so a planted program would run as
::     the student -- a smaller consequence over the same account, and the elevated child
::     :installwsl starts carries two program names of its own, spelled in full for this reason.
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
:: style choice. This file runs with the DOWNLOAD FOLDER as its working directory, and cmd.exe
:: searches the current directory BEFORE %PATH% -- so a wsl.exe sitting in Downloads is what a
:: bare `wsl.exe` runs. Downloads is the likeliest place on the machine for an untrusted file to
:: already be, and wsl.exe has nineteen call sites here, one of them the handoff to stage two.
::
:: AND "AS ADMINISTRATOR" IS NO LONGER PART OF THAT, WHICH CHANGES THE STAKES AND NOT THE RULE.
:: This file required elevation when #125 was reported, so a planted program ran with
:: Administrator rights; it refuses an elevated run now, so one would run as the student instead.
:: That is the student's whole account, their WSL environment and the fetch that executes stage
:: two, so the qualification stays exactly as load-bearing. An elevated path also still exists --
:: :installwsl asks for permission and starts a `cmd /c` naming two programs -- and those are
:: written out in full for this reason, in a place where %SYS32% would be the wrong answer.
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

:: TURNING WSL ON, WHICH IS THE ONE STEP THAT NEEDS AN ADMINISTRATOR -- so it ASKS, rather than
:: sending the student away to start over as somebody else. One UAC prompt, in the middle of an
:: otherwise ordinary run, and setup carries on afterwards.
::
:: A NEW PROCESS, BECAUSE A RUNNING ONE CANNOT BE ELEVATED. Windows has no seteuid: a token's
:: elevation is fixed when the process is created, and the elevated child is created by the
:: AppInfo service rather than by us. That is also why its output cannot come back here --
:: -Verb RunAs lives in Start-Process's UseShellExecute parameter set, where -NoNewWindow and
:: every -RedirectStandard* are absent, and there is no console or handle inheritance across the
:: boundary. -Wait and -PassThru ARE in every parameter set, so the EXIT CODE does come back, and
:: the caller re-asks `wsl --status` afterwards rather than reading the child's words.
::
:: ONE CHILD FOR BOTH COMMANDS, AND THEREFORE ONE PROMPT. Consecutive elevation requests are never
:: coalesced by Windows -- two Start-Process calls are two prompts -- so both go to a single
:: cmd.exe. `&` and not `&&`: --update is best effort, and cmd returns the LAST command's code,
:: which is exactly the one that matters.
::
:: WHAT THAT TRADES, stated because the header closes it elsewhere: for `cmd /c "a & b"` the
:: current-directory search is fixed once for the whole line, so NoDefaultCurrentDirectoryInExePath
:: cannot protect the second command -- and an elevated child would not inherit that variable from
:: us anyway. Both programs are named by full path, which is issue #125's actual fix and carries
:: the property on its own, and -WorkingDirectory takes the download folder out of the picture.
::
:: THREE ANSWERS. 0 the child ran and succeeded; 101 the prompt was declined or could not be
:: raised at all, which is a person saying no and not a broken computer; 102 the child ran and
:: failed. Distinct because the first two need different things said to the student, and 101 is
:: the arm a `try` is here for -- Start-Process THROWS when consent is refused.
set "PSELEV=$w=$env:SystemRoot+'\System32\wsl.exe'; $c=$env:SystemRoot+'\System32\cmd.exe'; $a='/c '+$w+' --update & '+$w+' --install --no-distribution'; try { $p=Start-Process -FilePath $c -ArgumentList $a -WorkingDirectory $env:SystemRoot -Verb RunAs -Wait -PassThru } catch { exit 101 }; if ($p.ExitCode -ne 0) { exit 102 }; exit 0"

:: One probe, used twice: before creating the environment and again afterwards. Batch cannot
:: read `wsl --list` directly -- its output is UTF-16, which breaks findstr and for /f alike --
:: so WSL_UTF8 makes it plain text and PowerShell does the comparison. The answer comes back
:: as an EXIT CODE rather than on stdout: 0 = present, 1 = absent, anything else = the probe
:: itself could not run, which is a different thing from "absent" and is handled separately.
::
:: ITS ANSWER IS THE RUNNING ACCOUNT'S, AND CANNOT BE ANYONE ELSE'S. WSL registers every
:: environment under HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss, with the VHD under that
:: user's %LOCALAPPDATA%\wsl, and there is no machine-wide registration at all -- measured on
:: Windows 11 26200, where HKLM's Lxss key holds only MSI, Plugins and DiskMounts. So `wsl -l -q`
:: cannot see another user's environments and cannot be made to. This is the line to read when an
:: environment that plainly exists is reported absent, or an absent one is reported present: the
:: question is which account asked. :isadmin is what makes that account the student's: an elevated
:: run is refused outright, so the only token that ever reaches this line is the one at the keyboard.
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

:: ---- must NOT be Administrator -----------------------------------------------
:: THIS USED TO REQUIRE ELEVATION, AND NOW IT REFUSES IT. The reversal is the fix for the defect
:: below, and the reasoning is that there is no longer any run for which elevation is correct:
::
::   * IF WSL IS ALREADY INSTALLED, everything left is per-user and elevation is simply wrong.
::   * IF WSL IS NOT, the one step that needs an administrator asks for permission itself, at the
::     moment it needs it -- see %PSELEV% above. Nothing is gained by starting out elevated.
::
:: WHAT REQUIRING IT COST. A standard user cannot be elevated as THEMSELVES: UAC asks for a
:: different administrator's credentials and the whole file then runs as that account. %APPDATA%,
:: %LOCALAPPDATA% and HKCU -- which is where WSL registers environments, there being no
:: machine-wide registration -- all follow the token. Measured on Windows 11 26200 on 2026-09-15
:: from a standard account authorised with a separate admin's password: %PROBE% found the ADMIN's
:: CS193V and skipped creation, stage two provisioned the ADMIN's environment, the shortcut and
:: icon were written into the ADMIN's profile, %PSDEL% deleted the ADMIN's `wsl --install` entry,
:: and the run exited 0 telling the student to open the entry from their own Start Menu. The
:: student's account got nothing. :shortcutfailed cannot fire for that: nothing failed.
::
:: AN UNCONDITIONAL REFUSAL RATHER THAN A COMPARISON OF IDENTITIES. The earlier fix here asked
:: whether the elevating account was the student's own -- comparing the process token's SID against
:: the owner of the Explorer in its session -- and carried on when they matched. That works, and it
:: is strictly more machinery for a case that should not exist: an elevated run is never the right
:: one, so the identity behind it does not need to be established. Refusing the whole class needs
:: no WMI, cannot be wrong about RDP or a domain-joined machine, and has nothing to fail open.
::
:: SO THIS IS THE ONLY PLACE ELEVATION IS ASKED ABOUT, and it is asked before any external call,
:: before %PROBE%, and before anything reads %APPDATA%. 25-installer.sh pins that ordering.
::
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
if %errorlevel% equ 0 goto isadmin

:: ---- is WSL present at all? ---------------------------------------------------
if not exist "%SYS32%\wsl.exe" goto installwsl
"%SYS32%\wsl.exe" --status >nul 2>&1
if %errorlevel% neq 0 goto installwsl
goto havewsl

:installwsl
:: THE ONE STEP THAT NEEDS AN ADMINISTRATOR, AND IT ASKS RATHER THAN SENDING ANYONE AWAY. The
:: student runs this file as themselves; Windows raises one prompt here; setup carries on. The
:: alternative -- refuse, and tell them to start again as an administrator -- is what this file
:: used to do, and for a standard user it can only end in somebody else's account owning the
:: course. See the refusal at :isadmin for the measurement.
::
:: ONE ARM AND NOT TWO. There is deliberately no "already elevated, so run the commands directly"
:: path, because :isadmin has already refused every elevated run: reaching here means this process
:: is not elevated, and the only way the machine-wide work happens is the child below. The cost is
:: that a failing `wsl --update` and a failing `wsl --install --no-distribution` can no longer be
:: told apart -- the child reports one code for both -- so :wslupdatefailed is gone and both land
:: on :wslfeaturefailed. That is the right trade for an arm that cannot be entered elevated at all.
echo   [1/3] Turning WSL on. This is a change to Windows itself, so
echo         Windows will ask for an administrator's permission.
echo.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PSELEV%"
if %errorlevel% equ 101 goto uacdeclined
if %errorlevel% neq 0 goto wslfeaturefailed
goto restartneeded

:restartneeded
:: TWO CALLERS NOW, both on the WSL-absent road: the self-elevating arm and the already-elevated
:: one. It used to have exactly one, and the count is worth keeping accurate because the placement
:: argument below depends on every caller reaching it going forward.
::
:: PLACED so that caller reaches it going FORWARD. A backward `goto` would work; cmd rescans from
:: the top of the file for a label. But this file keeps to a subset of batch that the test suite
:: can verify, and it has never contained one, so adding the first would be a construct to argue
:: about in exchange for nothing.
echo.
echo   ------------------------------------------------------------------
echo   RESTART YOUR COMPUTER NOW.
echo.
echo   After it restarts, run this same file again. It will carry on
echo   from here and will not need permission a second time.
echo   ------------------------------------------------------------------
echo.
pause
exit /b 0

:: EVERYTHING BELOW THIS LINE IS PER-USER, and belongs to whoever is sitting at the computer.
:: %APPDATA%, %LOCALAPPDATA% and HKCU -- which is where WSL registers environments; there is no
:: machine-wide registration -- all follow the TOKEN this process runs under. So an elevation
:: borrowed from another account would not merely fail to help here, it would silently do all of
:: it to that account instead.
::
:: WHAT MAKES THAT IMPOSSIBLE IS :isadmin, AT THE TOP, and nothing here re-checks it. There was a
:: guard at this point for one revision, asking whether the elevating account was the student's
:: own; refusing elevation outright made it unnecessary. If :isadmin is ever relaxed into a
:: conditional, every path below silently comes to belong to whoever answered the UAC prompt.

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
:: cmdlint-allow: unchecked-exit -- BEST EFFORT here, unlike inside %PSELEV% where the pair's code
:: is load-bearing. `wsl --update` on an already-current WSL is not contractually zero, and a
:: refusal from an optimisation would turn a working install into a failed one. If it mattered,
:: the install below fails and says so.
::
:: AND IT RUNS UN-ELEVATED NOW, WHICH IS A RESIDUAL WORTH KNOWING. Measured on Windows 11 26200 on
:: 2026-09-15: un-elevated `wsl --update` on an already-current WSL exits 0 in about a second
:: saying so, and raises no prompt. What is NOT measured is the same call on a machine that has an
:: update available -- WSL installs to %ProgramFiles%\WSL, so applying one needs an administrator,
:: and this could therefore raise a SECOND consent prompt at a point the student was not told to
:: expect one. It is left in place because on a machine with an old-but-working WSL it is the only
:: thing that reaches 2.4.4, which `--name` below requires, and because its failure is already
:: waived. If it does prove to prompt, the fix is to delete this line and let :distrofailed name
:: the version as the cause -- it already does -- with the remedy being to update WSL by hand.
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

:: ---- the Start Menu entry (#134) ---------------------------------------------
:: WHY THE WINDOWS HALF IS HERE AND THE REST OF IT IS NOT. Authoring a .lnk needs a Windows
:: process, which this is and course-install.sh is not; knowing $DIR needs course-install.sh,
:: which chose it. So install_win_shim writes a shim at a path that never varies and this points
:: a shortcut at that path. Nothing student-specific crosses the boundary, which is what keeps a
:: `for /f` capture out of this file and means none of it depends on WSL interop.
::
:: AFTER THE SIGN-OFF, UNAVOIDABLY. The shim only exists once stage two has run, and stage two
:: ends by printing finished.windows -- so a student has already been told about the Start Menu
:: entry by the time it gets made. finished.windows therefore keeps the typed commands as its
:: fallback, and the one failure arm below points back at them rather than printing a second
:: closing block of its own. That is the #218 boundary: one sign-off, and a correction is not one.
::
:: %SystemRoot%\System32 AND NOT %SYS32% FOR THE TARGET, and this is the only place in the file
:: where the difference matters. %SYS32% becomes %SystemRoot%\Sysnative on WOW64 (line 102), and
:: Sysnative is a redirector visible only to the 32-bit process looking at it -- correct for
:: RUNNING wsl here, meaningless once written into a shortcut that Explorer resolves later.
::
:: NOT wt.exe EITHER. Windows Terminal is an App Execution Alias whose backing path moves with
:: every Store update and which Settings can switch off; wsl opens in whatever the student's
:: default terminal is, which on Windows 11 22H2 and later is Windows Terminal anyway.
:: TWO DIRECTORIES, AND TELLING THEM APART IS THE WHOLE OF #270. %SMDIR% is the Start Menu
:: ROOT, which is where `wsl --install` puts its own entry; %LNKDIR% is the app list, which
:: is where ours goes. Derived from one another so the pair cannot drift, and the delete
:: below reads %SMDIR% rather than assuming both entries live in the same folder.
set "SMDIR=%APPDATA%\Microsoft\Windows\Start Menu"
set "LNKDIR=%SMDIR%\Programs"
set "LNKNAME=CS193V Development Environment"
set "ICODIR=%LOCALAPPDATA%\CS193V"
set "SHIMUNC=\\wsl.localhost\%DISTRO%\home\%LINUX_USER%"

if not exist "%ICODIR%" md "%ICODIR%"
copy /y "%SHIMUNC%\.cs193v-icon.ico" "%ICODIR%\cs193v.ico" >nul
if %errorlevel% neq 0 goto shortcutfailed

:: THE ICON IS COPIED OUT RATHER THAN POINTED AT. An IconLocation under \\wsl.localhost resolves
:: only while the distribution is running, and a stopped distribution is exactly the state a
:: student's Start Menu is in when they go looking for this.
::
:: bash -ic AND NOT A BARE `-- ~/.cs193v-enter`. The bare form makes the launcher the session
:: leader, which is the one shape in which #170 is deterministic; -i gives an interactive shell
:: with job control on, so the shim is a foreground job and the launcher its child, inside the
:: process group a window close signals.
set "PSLNK=$s = (New-Object -ComObject WScript.Shell).CreateShortcut('%LNKDIR%\%LNKNAME%.lnk'); $s.TargetPath = '%SystemRoot%\System32\wsl.exe'; $s.Arguments = '-d %DISTRO% --cd ~ -- bash -ic ~/.cs193v-enter'; $s.IconLocation = '%ICODIR%\cs193v.ico'; $s.Description = 'Start the CS193V development environment'; $s.Save()"
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PSLNK%"
if %errorlevel% neq 0 goto shortcutfailed

:: AND THE FILE IS THERE, which the exit code above does not say. A COM terminating error does
:: reach that code, but an unwritable directory, a policy-redirected Start Menu and a name
:: Explorer refuses are all "exited 0, no shortcut" -- and by this point stage two has already
:: promised the student the entry, so :shortcutfailed is the only channel left for the truth.
:: A builtin, so it adds no external call and no unchecked-exit obligation.
::
:: WHAT THIS DOES NOT CATCH, said here because it looks as though it should: a .lnk written into
:: the WRONG PROFILE. %APPDATA% is read here and %APPDATA% was read to write it, so both name the
:: same directory and this passes happily. :isadmin is what closes that, by refusing the only
:: state in which the two could differ; this is not a second guard against it, and reading it as
:: one is how the first would come to look redundant.
if not exist "%LNKDIR%\%LNKNAME%.lnk" goto shortcutfailed

:: ---- and remove the one wsl --install made -----------------------------------
:: `wsl --install` CREATED A START MENU ENTRY OF ITS OWN, named after the distribution, and it
:: opens a bare login shell in the home directory -- not the launcher, and not the course folder.
:: Two entries a letter apart is worse than either alone, so the plain one goes.
::
:: IT CANNOT BE RETARGETED INSTEAD. /etc/wsl-distribution.conf's [shortcut] section has exactly
:: two keys, `enabled` and `icon`; nothing there sets the command. The file is Canonical's and
:: lives inside the tarball besides, and `wsl --install` has already read it and written both
:: artifacts by the time line 332 can move it aside.
::
:: THE GUARD IS THE FILENAME AND A wsl TARGET, AND DELIBERATELY NOT THE ARGUMENTS. The obvious
:: check -- does it mention this distribution -- cannot work: WSL writes
:: `--distribution-id {GUID}`, not the name (microsoft/WSL#13414). So what is asserted is that
:: the file is named for the distribution and points at something called wsl. Failure here is
:: ignored on purpose: a leftover entry is untidy, not broken, and is not worth losing an
:: otherwise finished install over.
::
:: AND IT LOOKS IN THE START MENU ROOT, WHICH IS A MEASUREMENT AND NOT A READING OF THE DOCS
:: (#270). This used to read %LNKDIR% -- the app list, where the entry above goes -- so it
:: never removed anything, and because the call is waived below it said nothing about that.
:: Measured on Windows 11 26200.9445 with WSL 2.7.14.0: four environments created by
:: `wsl --install --name`, four .lnk in %APPDATA%\Microsoft\Windows\Start Menu, none under
:: Programs. Target is `C:\Program Files\WSL\wsl.exe` with `--distribution-id {GUID} --cd ~`,
:: so the wsl match was right all along; only the directory was wrong.
::
:: WHAT MADE THE WRONG GUESS PLAUSIBLE, recorded because it still looks like the right answer:
:: `wsl --install` ALSO creates an empty `Programs\<distro>\` DIRECTORY beside the root .lnk,
:: so a per-distro name really does appear under %LNKDIR%. It is a folder rather than a
:: shortcut, and an empty one renders nowhere in the app list. Deliberately left alone: a
:: directory a student may since have put something in is not ours to remove.
::
:: BOTH ARE CHECKED, and the second costs one Test-Path on a path that is normally absent.
:: Nothing documents where WSL writes this, the location has moved before, and a version that
:: put it in the app list instead would otherwise reintroduce this exact defect in this exact
:: way -- silently, because the failure of a delete that finds nothing is indistinguishable
:: from the success of one that had nothing to do.
set "PSDEL=foreach ($p in @('%SMDIR%\%DISTRO%.lnk', '%LNKDIR%\%DISTRO%.lnk')) { if (Test-Path -LiteralPath $p) { $t = (New-Object -ComObject WScript.Shell).CreateShortcut($p); if ($t.TargetPath -match 'wsl') { Remove-Item -LiteralPath $p -Force } } }"
:: cmdlint-allow: unchecked-exit -- attached HERE and not above the `set`, because
:: _cmdlint_waivers binds to the next non-comment line and `set` would consume it.
:: A leftover plain-shell entry is cosmetic: the install is complete and usable either
:: way, and there is no remediation worth offering a student for an extra Start Menu icon.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PSDEL%"
goto shortcutdone

:shortcutfailed
echo.
echo   The Start Menu entry could not be created. Everything else
echo   installed: use the commands shown above to start CS193V.

:shortcutdone

pause
exit /b 0

:uacdeclined
:: REPLACES :notadmin, WHICH ASKED FOR THE WRONG THING. That block refused every un-elevated run
:: and told the student to start over as an administrator -- which for a standard user means
:: borrowing somebody else's account, and that is the defect this whole change is about. This one
:: is reached only after permission was actually ASKED FOR and not given, so it is a person's
:: decision rather than a property of the computer, and the remedy is to run it again and allow it.
::
:: NOTHING HAS HAPPENED AT THIS POINT, and saying so matters: the prompt comes before any change,
:: so a student who clicked No has not left the machine half-configured.
echo   Setup needs permission to turn WSL on, and that permission was
echo   not given -- so nothing has been changed.
echo.
echo   Run install-cs193v-windows.cmd again and choose Yes when Windows
echo   asks. Turning WSL on is the only step that needs permission; the
echo   rest of setup runs as you.
echo.
echo   If you are asked for a password you do not have, whoever looks
echo   after this computer has to allow that one step for you. Everything
echo   after it you can do yourself.
echo.
pause
exit /b 1

:isadmin
:: THE REFUSAL THAT REPLACED A REQUIREMENT. This file used to insist on being run as an
:: administrator; it now refuses to be. See the reasoning at the probe above -- in short, an
:: elevated run is never the right one, so its identity never has to be established.
::
:: THE PAIR TO :foreignaccount BELOW, one layer out. That one refuses because somebody else's
:: LINUX account owns the environment; this one because an elevated run would make somebody else's
:: WINDOWS account own everything setup is about to write. Same shape: say so, change nothing, stop.
::
:: IT DOES NOT NAME THE OTHER ACCOUNT, and that is a constraint rather than a choice: reading a
:: VALUE back out of a probe needs `for /f` or a scratch file in %TEMP%, and both are banned -- see
:: the header. It does not need to. What the student has to change is the way they start the file,
:: and %USERNAME% here is free from the environment and is the account that would have owned it.
echo   Do not run setup as an administrator -- it has stopped without
echo   changing anything.
echo.
echo   Almost everything setup does belongs to ONE Windows account: the
echo   CS193V environment, the Start Menu entry, your files. Running as
echo   an administrator gives all of it to whichever account answered
echo   the prompt -- %USERNAME% here -- and not necessarily to yours.
echo.
echo   Start it again the ordinary way, as yourself. If WSL still has to
echo   be turned on, setup will ask for permission for that one step
echo   when it gets there.
echo.
pause
exit /b 1

:: :wslupdatefailed WAS HERE, AND IS GONE RATHER THAN LEFT UNUSED -- the same standard the header
:: applies to the sibling lookup and the scratch file. `wsl --update` used to run on the
:: :installwsl arm as a checked command with a message of its own; it now runs inside the elevated
:: child next to `wsl --install --no-distribution`, and cmd returns one exit code for the pair. So
:: the distinction is not merely unreported, it is unrecoverable, and a label nothing can reach
:: would be a message that reads as available and is not. A failing update arrives at
:: :wslfeaturefailed, whose words cover it: the feature did not get turned on.

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

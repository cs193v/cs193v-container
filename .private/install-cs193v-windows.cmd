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
:: AND THERE IS NOW A .ps1 ANYWAY, WHICH DOES NOT CONTRADICT THE PARAGRAPH ABOVE (#299). Both
:: reasons in it are facts about a file SAVED ON DISK. install-cs193v.ps1 is never saved: a
:: student pastes `irm <address> | iex`, `iex` runs a STRING, execution policy governs FILES, and
:: a string carries no mark of the web either. So neither reason reaches the launcher and both
:: still reach this file, which is why the launcher may be PowerShell and the installer may not.
:: What keeps that split honest is that the launcher contains NO INSTALLER LOGIC -- it downloads
:: one file, checks its SHA-256, and starts it -- and 25-installer.sh asserts that it never so
:: much as names wsl.exe. The assertion that used to forbid a .ps1 outright is gone, replaced by
:: that one; see the winboot:* block for the reasoning.
::
:: THE MARK OF THE WEB REACHES A .cmd TOO, which this header used to deny -- "a .cmd just runs".
:: Measured 2026-09-15: a copy downloaded from a browser carries a Zone.Identifier stream
:: [ZoneTransfer] ZoneId=3, and Windows then refuses to run it from a double-click. The difference
:: from a .ps1 is that it is the Attachment Manager rather than a policy, so launching the file by
:: its full path runs it -- there is nothing to unblock and nothing to teach anyone to override.
::
:: THAT MARK DEPENDS ON HOW THIS FILE ARRIVED, and since #299 there are two ways. A browser
:: download carries the stream and is refused from a double-click, as above. The copy the
:: bootstrap writes carries NONE: the mark is applied by the Attachment Manager on a browser's
:: behalf, not by the .NET HTTP stack Invoke-WebRequest uses, so a file written that way has only
:: a $DATA stream. Nothing in this file depends on which way it came, and no message here names
:: one -- the course instructions carry the gesture.
::
:: RUN IT AS YOURSELF. ON A MACHINE WITHOUT WSL IT STILL TAKES TWO RUNS, but since #275 you
:: normally only start the first one. Turning on a Windows feature needs a restart, so the first
:: run asks Windows for permission for that one step -- one UAC prompt, mid-run -- registers a
:: RunOnce entry naming this file, and says to restart. Windows starts the second run itself at
:: the next sign-in, and that one asks for no permission. If the entry cannot be written, or
:: something on the machine removes it, the notice says to rerun the installer by hand instead
:: and that still works exactly as it did. If WSL is already on, one run does everything and
:: nothing asks for permission at all. It is safe to run any number of times.
::
:: AND "RERUN THE INSTALLER" IS NOW THE WORDING EVERYWHERE, rather than "run this file again"
:: (#299). Under the one-liner this file lives in %LOCALAPPDATA%\CS193V, which no student has
:: ever navigated to, so a message naming "this file" named something they could not find. None
:: of them says HOW any more, because the answer differs by gesture and the one that works is
:: whichever one they used the first time.
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
::   https://raw.githubusercontent.com/cs193v/cs193v-container/release-0.0.0/.private/install-cs193v.sh
::
:: Reading this file therefore tells you everything that will run on your computer. Stage 2 is
:: fetched over HTTPS INSIDE the CS193V environment, checked against a SHA-256 before it is
:: run, and left at /var/tmp/install-cs193v.sh in there so you can read it afterwards.
::
:: It used to be a file you had to download YOURSELF and leave next to this one. That is gone:
:: two downloads meant two things to get right, and the one that went wrong silently was a
:: stale copy from an earlier quarter, which looks like a working install and is not.
::
:: NOTHING IS DOWNLOADED ONTO WINDOWS ITSELF, AND ONE REQUEST IS NOW MADE FROM IT. Since #275
:: the create waits for a network first, which is one HTTPS HEAD of the URL above -- nothing is
:: read from the response and nothing is written to disk. The consequence worth knowing, since
:: the note above about the mark-of-the-web is what makes this a .cmd: that mark is an NTFS
:: alternate data stream, and stage 2 lands on the environment's own Linux filesystem, so it can
:: never carry one.
::
:: THAT SENTENCE IS ABOUT WHAT THIS FILE DOES, AND SINCE #299 IT IS NOT TRUE OF HOW THIS FILE
:: ARRIVED. Under the one-liner THIS file is itself a download onto Windows: install-cs193v.ps1
:: fetches it from the raw URL at the pinned tag, checks its bytes against a SHA-256 compiled
:: into that script, converts the LF endings git stores back to the CRLF cmd.exe needs, and
:: writes it to %LOCALAPPDATA%\CS193V. So the chain a reader should have in mind is three links,
:: not two: the .ps1 pins this file, this file pins stage 2, stage 2 pins the course tree. Only
:: the .ps1 is unchecked, and it is short enough to read at its address.
::
:: TWO FILES AND ONE REGISTRY VALUE ARE WRITTEN TO THE WINDOWS SIDE, AND UNTIL #134 THERE WERE
:: NONE. The paragraph above used to read "nothing is downloaded onto Windows itself" and was
:: taken to mean this file touches nothing out there at all, which is no longer true. The Start
:: Menu section near the end creates
::
::     %APPDATA%\Microsoft\Windows\Start Menu\Programs\CS193V Development Environment.lnk
::     %LOCALAPPDATA%\CS193V\cs193v.ico
::
:: and deletes the Start Menu entry `wsl --install` made. Neither is downloaded -- the icon is
:: copied out of the environment over \\wsl.localhost, so the mark-of-the-web argument above
:: still holds for both. The third arrived with #275 and is transient:
::
::     HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce  ->  CS193VSetup
::
:: written only on the road that asks for a restart, deleted by Windows before it runs it, and
:: deleted again at :havewsl for the run where it never did.
::
:: AND UNDER THE ONE-LINER THERE IS A FOURTH, WRITTEN BY THE .ps1 RATHER THAN BY THIS FILE:
::
::     %LOCALAPPDATA%\CS193V\install-cs193v-windows-<release>.cmd
::
:: which is THIS file, and it is deliberately the same folder cs193v.ico already lives in. It has
:: to outlive the restart, because the RunOnce value above names it BY ABSOLUTE PATH -- which is
:: also why it is not in %TEMP%, which Storage Sense empties out of the box, and not in Downloads,
:: which it can be configured to empty and which students empty by hand. Measured on Windows 11
:: 26200: StoragePolicy has 01=1 and 04=1, and no value for the Downloads cleanup, which defaults
:: to Never -- so that second one is a weaker hazard than the first and is still a real one. The
:: name carries the release so two
:: can sit side by side, and so a newer paste cannot overwrite the copy an earlier run verified
:: and a pending RunOnce entry still points at.
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
::     this file runs from a folder the student can write to, so a bare `wsl.exe` would run a
::     copy planted there. Every external program is named through %SYS32%; the block just below
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
:: style choice. This file runs with WHATEVER DIRECTORY LAUNCHED IT as its working directory,
:: and cmd.exe searches the current directory BEFORE %PATH% -- so a wsl.exe sitting there is
:: what a bare `wsl.exe` runs. wsl.exe has nineteen call sites here, one of them the handoff
:: to stage two.
::
:: IT USED TO NAME THE DOWNLOAD FOLDER, AND THE RULE IS UNCHANGED BY ITS NO LONGER BEING ONE.
:: Under the hand gesture the working directory is Downloads: the likeliest place on the
:: machine for an untrusted file to already be. Under the one-liner (#299) it is wherever the
:: student's shell happened to be, normally %USERPROFILE%. That is a less likely place to find
:: a planted wsl.exe and an equally writable one, which is all #125 needs -- the qualification
:: below is about what cmd.exe WOULD resolve, not about how probable the plant is.
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

:: ---- where this file is, which is asked once and used once (#275) -----------
:: CAPTURED BEFORE THE `cd` BELOW, and the order is the whole of it. %~f0 is expanded
:: against the batch file cmd is running, but reading it while the working directory is
:: still the one the student launched from removes the question rather than relying on
:: the answer -- the same reason NoDefaultCurrentDirectoryInExePath is set before the
:: first external call rather than merely somewhere above it. 25-installer.sh pins the
:: ordering, and pins that this is the only batch-parameter substitution in the file.
::
:: THE HEADER USED TO BAN THIS OUTRIGHT, and the ban is narrowed rather than dropped.
:: What %~dp0 was banned FOR was %HERE%: a second route to stage two, a sibling
:: install-cs193v.sh beside this file, which went stale between quarters and looked
:: exactly like a working install. Relaunching THIS file is not that route. %SELF% goes
:: into one registry value and nowhere else, and 25-installer.sh asserts it never
:: reaches wsl.exe -- which is the property the old ban was actually protecting.
::
:: %~f0 AND NOT %~dp0. The whole path, because what is wanted is the file and not the
:: folder, and nothing here ever joins a name onto a directory.
::
:: THE ORDERING NOW PROTECTS THE HAND GESTURE ONLY, AND IS KEPT FOR EXACTLY THAT (#299).
:: install-cs193v.ps1 starts this file by absolute path, so under the one-liner %~f0 is
:: already absolute and the `cd` below could not have changed the answer. A student who
:: downloaded the file and typed a relative name is the case that still depends on the
:: order, and it is still a real case -- the one-liner is an addition, not a replacement.
:: So the assertion stays and this note says what it is now for, rather than the line
:: quietly becoming decoration that the next reader deletes.
set "SELF=%~f0"

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
:: directory -- wslpath and %TEMP% are banned, %~f0 is read once and only into %SELF%, and
:: 25-installer.sh asserts all three -- and every value crossing into Linux is an absolute path,
:: so the distro starting in /mnt/c/windows is inert. Deliberately unchecked: `cd` is a builtin,
:: and if it somehow failed the qualification above still carries the property on its own.
::
:: THE BAN ON KNOWING WHERE THIS FILE IS WAS NARROWED BY #275, NOT DROPPED. It read "%~dp0,
:: wslpath and %TEMP% are all banned", and what it was protecting was that stage two has exactly
:: ONE route: %HERE% used to point at a sibling install-cs193v.sh, which went stale between
:: quarters and looked precisely like a working install. Relaunching THIS file after a restart is
:: not that route. So the file may now know its own path, once, and 25-installer.sh pins the
:: narrowness rather than the ban -- one substitution in the whole file, it is %~f0, read before
:: `cd` above, and the value it produces never reaches wsl.exe.
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
:: REPO_NAME and REPO_TAG; 25-installer.sh asserts that they do, because a mismatch would
:: quietly fetch the wrong course's installer and nothing would notice until it ran.
::
:: A TAG, NOT A BRANCH (#232). raw.githubusercontent.com serves whatever ref you name, so this
:: used to track main and every Windows student got whatever had last been pushed. It is now the
:: release, and STAGE2_SHA256 below is checked against the bytes that arrive -- which is why this
:: is no longer the one line a TA edits by hand: the tag and the digest move TOGETHER, and
:: .private/release.sh is what moves them. Editing this alone gets you a refusal, correctly.
set "REPO_OWNER=cs193v"
set "REPO_NAME=cs193v-container"
set "REPO_TAG=release-0.0.0"
set "INSTALLER_URL=https://raw.githubusercontent.com/%REPO_OWNER%/%REPO_NAME%/%REPO_TAG%/.private/install-cs193v.sh"
:: AND ONE WAY TO POINT IT SOMEWHERE ELSE, FOR STAFF (#280). Unset, this changes nothing; set,
:: it replaces the whole URL, so a by-hand test can serve stage two out of a working tree --
:: curl inside %DISTRO% takes file:///mnt/c/... and the real download path is still what runs.
::
:: `if defined` AND NOT A SECOND `set "INSTALLER_URL=..."` AT TOP LEVEL, which matters more than
:: it looks. 25-installer.sh and 00-release-gates.sh both read this constant with a sed anchored
:: at `^set "INSTALLER_URL=`, taking the first match -- so a second bare assignment would be what
:: they compare against the .sh, and the release gate would fetch a placeholder. This line starts
:: with `if`, so both readers look straight past it. Same shape as the SYS32 line above.
if defined CS193V_INSTALLER_URL set "INSTALLER_URL=%CS193V_INSTALLER_URL%"

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

:: WHAT TO HAND STAGE TWO BESIDES ITS OWN SWITCH, AND NORMALLY NOTHING (#280). CS193V_TARBALL
:: tells install-cs193v.sh to install from a local tarball instead of downloading one; this
:: carries it across the Windows/Linux boundary on the two `wsl -e env` lines below.
::
:: THE QUOTED `set` FORM IS WHAT KEEPS THE TRAILING SPACE, so with the variable unset %XENV% is
:: empty and both of those lines render exactly as they did before this existed -- which is the
:: property 25-installer.sh pins and the wine tier proves at run time by counting argv.
::
:: IT GOES INSIDE `env`'s ARGUMENT LIST, never at the start of a line: cmdlint reads the first
:: word of every command and demands %SYS32%\, so a token in front of wsl.exe fails
:: windows:every-program-is-fully-qualified regardless of what it expands to.
::
:: NO QUOTING IS APPLIED, so the value must not contain a space, &, |, >, ^ or %. That is a staff
:: path and the restriction is documented in .private/README.md rather than enforced here; ! is
:: safe because this file refuses EnableDelayedExpansion (see the header).
set "XENV="
if defined CS193V_TARBALL set "XENV=CS193V_TARBALL=%CS193V_TARBALL% "

:: What the downloaded setup script has to hash to (#232).
::
:: WHAT THIS REPLACED, and why the replacement is not merely stronger. It used to be SENTINEL, a
:: token on install-cs193v.sh's LAST line which the download was grepped for: finding it proved
:: the whole file arrived, because it was last. What it could not prove is that the file was OURS.
:: A digest proves both, so the token is gone rather than kept beside it -- keeping both would
:: leave one of them unreachable by any fixture, since no body can fail the token without also
:: failing the digest.
::
:: THE DIGEST OF THE BLOB raw.githubusercontent.com SERVES, which is not automatically the digest
:: of a file in a checkout: .gitattributes gives install-cs193v.sh `text eol=lf` so the two agree
:: on every platform, and .private/release.sh hashes the STAGED blob rather than the working copy
:: for the same reason. See .gitattributes' note on the two published files.
set "STAGE2_SHA256=43bfba9b94009ae2c151d09b16ca826fadb9a9fe434727aa8cf472148655ded2"

:: AND ONE WAY TO POINT IT SOMEWHERE ELSE, FOR STAFF -- the same shape CS193V_INSTALLER_URL has.
:: It REPLACES the expected value and never disables the check, so a by-hand test of an edited
:: bootstrap still has to supply the right number.
::
:: `if defined` AND NOT A SECOND `set "STAGE2_SHA256=..."` AT TOP LEVEL, for the reason the URL
:: override gives: 25-installer.sh and 00-release-gates.sh read this constant with a sed anchored
:: at `^set "STAGE2_SHA256=`, taking the first match, so a second bare assignment would become
:: what they compare and what the release gate treats as the pin.
::
:: IT ANNOUNCES ITSELF, unlike the URL override, which announces itself by printing the URL it is
:: about to fetch. This one changes nothing else a student can see, and a check that was quietly
:: pointed at a different expectation is the kind of thing a transcript has to be able to answer.
if defined CS193V_STAGE2_SHA256 set "STAGE2_SHA256=%CS193V_STAGE2_SHA256%"
if defined CS193V_STAGE2_SHA256 echo   *** CS193V_STAGE2_SHA256 is set, so the setup script is checked against it. ***

:: And the question that asks it.
::
:: A POWERSHELL PROBE, WHICH IS THIS FILE'S OWN IDIOM for asking something and branching on the
:: answer -- see %PROBE%, %VMFAILPROBE% and %PSNETWAIT%. Three states, like the getent pair below:
:: 0 the digests match, 1 they do not, 2 the question could not be asked.
::
:: AND 2 REFUSES RATHER THAN CONTINUING, which is the one place this file departs from "a failed
:: question is not a negative answer". Everywhere else that doctrine spares a student a refusal
:: they do not deserve; here it would hand root inside the distro a file nothing had checked.
::
:: WHY NOT `wsl -e sha256sum` AND A `for /f`. Reading a value back out needs either a capture,
:: which wine cannot execute at all -- it shells out to a nested CMD.EXE /C that never launches --
:: or a scratch file on the Windows side, and %TEMP%, %HERE% and wslpath are all refused because
:: they were the three legs of the route this file used to have before it downloaded anything.
:: wsl's own output is UTF-16 as well, which is why $env:WSL_UTF8=1 leads every probe here.
::
:: IT PRINTS WHAT IT RECEIVED on a mismatch, because the batch side cannot: with no capture there
:: is no way for it to learn the number. Between the probe's line and the refusal's, a student's
:: screenshot carries both digests -- which is the difference between staff guessing and staff
:: knowing, since a cut-short transfer and a mis-cut release land here identically and only the
:: numbers say which.
::
:: THE EXPECTED DIGEST IS SINGLE-QUOTED IN THE STRING, like %DISTRO% in %PROBE%. The fake
:: powershell the windows tier runs reads it back out of its own command line with quoted_after(),
:: which finds a single-quoted literal after a spelled-out prefix -- so the fixture judges the
:: value THIS FILE supplied rather than one the harness invented. No double quotes anywhere in the
:: string: batch would end the `set` at the first one.
::
:: -join ' ' FIRST, because `& $w` yields an ARRAY when the command prints more than one line and
:: -split on an array does not do what it looks like it does.
set "PSHASH=$env:WSL_UTF8=1; $w=$env:SystemRoot+'\System32\wsl.exe'; $o=(& $w -d %DISTRO% -u root -e sha256sum %STAGE2%) -join ' '; if ($LASTEXITCODE -ne 0) { exit 2 }; $h=($o -split '\s+')[0]; if ($h -eq '%STAGE2_SHA256%') { exit 0 }; Write-Host ('  received: ' + $h); exit 1"

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

:: ---- the entry that resumes setup after the restart (#275) -------------------
:: WHAT GETS WRITTEN, SPELLED OUT HERE SO IT CAN BE READ WITHOUT RUNNING ANYTHING. One value under
:: the current user's RunOnce key, holding one command line that starts this same file. Windows
:: removes the value before running it, so it is gone by the time setup reopens; :havewsl removes
:: it too, for the student who re-ran the file by hand before logging off.
::
:: BUILT HERE IN BATCH RATHER THAN INSIDE THE POWERSHELL BELOW, and that is a testability
:: decision rather than a style one. The fake powershell the test suite runs records this value
:: verbatim out of the environment; if PowerShell assembled it instead, out of %SystemRoot% and
:: the script path, the fake would have to assemble the expected answer the same way -- and a
:: fixture that agrees with the installer's reasoning cannot contradict it. That is how #270
:: shipped, and .private/README.md records it.
::
:: `set "VAR=..."` ENDS AT THE LAST QUOTE ON THE LINE, so the doubled quotes below survive intact
:: and a path containing a space needs nothing else done to it. Delayed expansion is off -- the
:: header says why, and 25-installer.sh asserts it -- so a `!` in the path survives too.
set "RESUMEKEY=HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
set "RESUMENAME=CS193VSetup"

:: cmd.exe AND NOT THIS FILE DIRECTLY. A RunOnce value is handed to CreateProcess, which cannot
:: execute a .cmd at all -- a batch file needs the interpreter named -- so the value starts with
:: cmd.exe and this file is its argument.
::
:: /s IS THE PART THAT SURVIVES A REAL STUDENT'S PROFILE. Without it, `cmd /c "path"` keeps the
:: outer quotes only when the quoted text contains whitespace AND contains none of & ^ ( ), and
:: strips them otherwise -- so it happens to work for `C:\Users\jo\Downloads\` and breaks for an
:: account called `Tom & Jerry`. With /s cmd removes exactly the first and last quote and runs the
:: rest verbatim, which is the same answer for every path.
::
:: %SystemRoot%\System32 AND NOT %SYS32%, and this is the second and last place in the file where
:: that difference matters -- the other is the .lnk target near the end. %SYS32% becomes
:: %SystemRoot%\Sysnative in a 32-bit process, and Sysnative is a redirector visible only to the
:: process looking at it: right for launching wsl.exe from here, meaningless once written into a
:: registry value that something else resolves after a reboot.
set "RESUMECMD=%SystemRoot%\System32\cmd.exe /s /c ""%SELF%"""

:: THE VALUE TRAVELS IN THE ENVIRONMENT AND IS NEVER INTERPOLATED INTO THIS STRING. A student's
:: path can hold an apostrophe, a quote, an ampersand or a percent sign, and each of those breaks
:: a PowerShell string that cmd's expander built. $env: is read by PowerShell itself, long after
:: cmd has finished parsing, so none of them can reach the parser. Same idiom as %PSELEV% above.
::
:: -Force so the value is created when it is absent and overwritten when a previous run left one.
:: The RunOnce key itself is present on a stock Windows, so nothing here creates it; if some
:: policy or cleanup has removed it, Set-ItemProperty fails, the read-back fails with it, and
:: :restartmanual prints the wording that needs no entry. Measured on 5.1.26100.9444 on
:: 2026-09-16: writing this value to a key that does not exist exits 1 rather than creating it.
set "PSRESUME=Set-ItemProperty -Path '%RESUMEKEY%' -Name '%RESUMENAME%' -Value $env:RESUMECMD -Force; if ((Get-ItemProperty -Path '%RESUMEKEY%' -Name '%RESUMENAME%' -ErrorAction SilentlyContinue).'%RESUMENAME%' -ne $env:RESUMECMD) { exit 1 }; exit 0"

:: REMOVING IT IS ALLOWED TO FIND NOTHING. On the road this feature is for, Windows has already
:: deleted the value by the time setup reopens, so the ordinary case is a no-op.
set "PSRESUMECLEAR=Remove-ItemProperty -Path '%RESUMEKEY%' -Name '%RESUMENAME%' -ErrorAction SilentlyContinue"

:: ---- waiting for the network, which is what resuming at logon costs (#275) ---
:: A RunOnce entry fires EARLY. The Run key and the Startup group are documented as deliberately
:: delayed by Windows "to a time when they are less likely to interfere with the foreground user
:: experience"; RunOnce is not in that sentence. So setup can now reach the 600 MB create a second
:: or two before the wifi has associated, which it never could when a student started it by hand.
::
:: THE LOOP IS IN HERE AND NOT IN BATCH, for the reason :restartneeded gives: a retry loop in
:: batch needs a backward `goto` and this file has never contained one. It is also one process
:: instead of twenty-four.
::
:: BOUNDED BY THE CLOCK AND NOT BY A COUNT OF TRIES. Twenty-four attempts with a five-second
:: connect timeout is four minutes of wall clock, and the student was told two.
::
:: ...BUT NEVER FEWER THAN TWO TRIES, AND THE FLOOR IS CONJOINED WITH THE DEADLINE ON PURPOSE. A
:: first attempt that hangs -- no resolver yet, a half-associated link, a stalled lookup outliving
:: -TimeoutSec -- can spend the whole budget by itself, and a bare deadline test would then make
:: this a single try wearing a loop's clothes. Catching a network that comes up a moment later is
:: the entire reason this exists, so it always looks twice. An `-or` here instead of `-and`
:: restores that defect and changes nothing anyone would see; 25-installer.sh pins the `-and`.
::
:: IT ASKS THE HOST IT ACTUALLY NEEDS, over HTTPS, rather than asking Windows whether it feels
:: connected. Not ping: campus networks drop ICMP as a matter of course, and a resolved name with
:: a dropped echo is ambiguous in the direction that refuses a working machine. A real request
:: also fails a captive portal, which answers DNS and completes a connection and is the case a
:: reachability flag cannot see. Not a machine property either -- every one of those is the
:: proxy-with-a-blind-spot shape #112 and #114 were both about.
::
:: WHAT IT DOES NOT PROVE, said plainly because the message on failure is confident: this reaches
:: GitHub, and `wsl --install -d` below pulls from Microsoft's distribution CDN. They can
:: disagree. That is why :nonetwork tells the student to run the file again rather than telling
:: them their computer cannot do this -- the bound is a delay, not a verdict.
::
:: $null = RATHER THAN A PIPE TO Out-Null. Pipes are banned throughout this file; under wine one
:: aborts the whole script with exit 255. Nothing here needs one.
::
:: A DOT PER ATTEMPT, so a two-minute wait does not read as a hang. It is punctuation rather than
:: prose, so nothing has to be added to the message table for it.
:: MEASURED, because no tier runs this loop. On Windows PowerShell 5.1.26100.9444 on 2026-09-16,
:: against a working connection, the whole command exits 0 in 1.06 s -- one attempt, no sleep, no
:: dot printed. So the ordinary student pays about a second for it, which is the number that makes
:: this worth having in front of the create rather than only on the resumed road.
set "PSNETWAIT=$ProgressPreference='SilentlyContinue'; $deadline=(Get-Date).AddSeconds(120); $n=0; while ($true) { $n++; try { $null = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 5 -Uri $env:INSTALLER_URL; exit 0 } catch { }; if ($n -ge 2 -and (Get-Date) -ge $deadline) { exit 1 }; Write-Host -NoNewline '.'; Start-Sleep -Seconds 5 }"

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
:: and %SYS32% names whichever of the two is the native one. It also succeeds for SYSTEM, and
:: since #277 that means SYSTEM is refused along with every other elevated context. This
:: sentence used to say the opposite, and it was true when elevation was REQUIRED: the probe
:: succeeding meant getting IN. It now means `goto isadmin`. So a management agent pushing
:: this out is turned away, and that is the unconditional refusal above working as written
:: rather than a gap in it -- an elevated run installs into whatever profile its token names,
:: and SYSTEM's is nobody's.
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
:: ONE CALLER, and the count is worth keeping accurate because the placement argument below
:: depends on every caller reaching it going forward. It said "two callers now" while an
:: already-elevated arm existed; #277 deleted that arm and left the sentence behind.
::
:: PLACED so that caller reaches it going FORWARD. A backward `goto` would work; cmd rescans from
:: the top of the file for a label. But this file keeps to a subset of batch that the test suite
:: can verify, and it has never contained one, so adding the first would be a construct to argue
:: about in exchange for nothing. The same rule is why the network wait's retry loop lives inside
:: PowerShell rather than being spelled out here.
::
:: ---- ask Windows to start setup again after the restart (#275) --------------
:: THE SECOND RUN IS THE ONE STUDENTS LOSE, and it is not because the instruction is unclear. It
:: asks them to remember something across a reboot, find a file in their downloads, and start it
:: BY FULL PATH -- because the copy they downloaded carries a Zone.Identifier stream and the
:: Attachment Manager refuses a double-click. So Windows is asked to do it instead.
::
:: HKCU AND NOT HKLM, WHICH IS THE SAME ARGUMENT AS :isadmin ONE LAYER OUT. HKLM's RunOnce runs
:: only when a member of the Administrators group logs on, and it runs ELEVATED -- so the resumed
:: run would meet the refusal at the top of this file and stop, on exactly the machine this exists
:: for. HKCU needs no elevation to write and its entry runs in the student's own session under
:: their own token, which is the account everything below :havewsl has to belong to.
::
:: WINDOWS DELETES THE VALUE BEFORE IT RUNS IT, and that is the whole safety property. An entry
:: that is malformed, or that names a file the student has since deleted, fires once and is gone.
:: A `!` prefix on the name would defer that deletion until after the command completed, which
:: turns an entry that cannot start at all into a window at every logon for the life of the
:: machine. There is no `!` here and 25-installer.sh keeps it that way.
::
:: REGISTERED AFTER CONSENT AND NOT BEFORE. :uacdeclined tells the student that nothing has been
:: changed; an entry armed ahead of the prompt would reopen, at the next logon, a setup they had
:: just said no to.
::
:: AND THE WRITE IS READ BACK, because "exited 0 and wrote nothing" is a state this file has been
:: caught by before -- #270's delete looked in the wrong directory and reported nothing, and
:: #134's .lnk needed an `if not exist` after its exit code for the same reason. Here the answer
:: also chooses the message: a promise that setup will reopen is only printed once the registry
:: has been asked whether it kept it.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PSRESUME%"
if %errorlevel% neq 0 goto restartmanual
echo.
echo   ------------------------------------------------------------------
echo   RESTART YOUR COMPUTER NOW -- use Restart, not Shut down.
echo.
echo   Setup will open again by itself when you sign back in, and will
echo   finish the job. Nothing will ask for permission a second time.
echo.
echo   If it does not open, rerun the installer. It will carry on
echo   from here.
echo   ------------------------------------------------------------------
echo.
pause
exit /b 0

:restartmanual
:: THE SAME RESTART, PROMISING NOTHING. Reached when the entry could not be written or did not
:: read back -- antivirus, a policy-locked hive, a profile path past RunOnce's 260-character
:: limit. None of those is a broken install and none is worth stopping for: this is the wording
:: this file carried before #275, and the run still exits 0 because nothing has failed.
::
:: WHY THE TWO MESSAGES ARE NOT ONE WITH A CONDITIONAL CLAUSE: a student reads the first sentence
:: and stops. "Setup will open by itself" and "run this file again" are different instructions,
:: and printing both with a hedge between them is how someone ends up waiting for a window that
:: is never coming.
::
:: USE RESTART, NOT SHUT DOWN, in both. With Fast Startup on -- which is the default -- a shutdown
:: is a hybrid one: the user session ends but the kernel session is hibernated, and Microsoft
:: documents that pending servicing operations do not complete across it. Turning a Windows
:: feature on is exactly such an operation. A restart is always a full boot.
echo.
echo   ------------------------------------------------------------------
echo   RESTART YOUR COMPUTER NOW -- use Restart, not Shut down.
echo.
echo   After it restarts, rerun the installer. It will carry on
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
:: ---- disarm anything the reboot road left behind (#275) ----------------------
:: NOT FOR THE ROAD THAT ARMED IT. Windows deletes a RunOnce value before running it, so
:: a setup that reopened by itself already has nothing to clear. This is for the student
:: who ran the file again BY HAND before logging off: the entry is still armed, and
:: without this they get a window at the next logon re-running an install that finished.
::
:: HERE AND NOT AT THE TOP OF THE FILE, so that :isadmin can keep saying it stopped
:: without changing anything. Everything from this label down is per-user work, and
:: removing a value from the running account HKCU is per-user work like the rest of it.
::
:: cmdlint-allow: unchecked-exit -- AND THE ORDINARY RUN FAILS THIS CALL, which is the measurement
:: that makes the waiver necessary rather than tidy. Measured on Windows PowerShell 5.1.26100.9444
:: on 2026-09-16: `Remove-ItemProperty -ErrorAction SilentlyContinue` on a value that is not there
:: exits 1. SilentlyContinue suppresses the MESSAGE and not the failure. Almost every run has
:: nothing to clear, so checking this code would refuse almost every install. fake-powershell.c
:: returns the same 1 for the same reason, so removing this waiver turns the tier red rather than
:: shipping. Beyond that: a leftover entry is an untidy re-run of an install that is already
:: complete and already idempotent, which is not worth failing a finished setup over -- the same
:: trade as the %PSDEL% waiver near the end.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PSRESUMECLEAR%"


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
:: ---- is there a network to download over? (#275) ----------------------------
:: ASKED HERE AND NOWHERE ELSE: this is the road that downloads, and `wsl --update` just
:: below is the first call on it that needs a network at all. A student whose environment
:: already exists skips this label entirely and pays nothing.
::
:: IT MATTERS NOW BECAUSE OF WHO STARTED THE RUN. Until #275 a student typed this when
:: they were ready; it can now be started by Windows at logon, seconds before the wifi
:: associates. See %PSNETWAIT% above for what is asked and what that does not prove.
echo         Checking that the internet is reachable. This can take up
echo         to two minutes if the computer has only just started up.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PSNETWAIT%"
if %errorlevel% neq 0 goto nonetwork

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
:: WHO ACTUALLY RUNS AS WHAT, because this used to say "the download and the install both run as
:: the student's LINUX user" and that conflated three separate claims (#232). Separately:
::
::   * This file, on the WINDOWS side, runs as the student. :isadmin refuses anything else.
::   * The download and the FIRST installer pass run as ROOT inside the distro. The download is
::     `-u root` so that re-running can overwrite a root-owned %STAGE2% from an earlier run, and
::     the first pass has to be root because it creates the student's account.
::   * The SECOND pass -- the install a Mac or Linux student sees -- runs as %LINUX_USER%.
::
:: So the blast radius of an unverified stage two is root inside the CS193V distro, which reaches
:: the student's Windows profile through drvfs but not the machine. That is why the digest check
:: below sits above the FIRST bash call and not merely above the second.
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
:: install-cs193v.sh's own download step carries the same guard for the same reason -- there it is
:: a manifest of everything in the tarball, here it is the digest of this one file.
::
:: AND IT IS ABOVE BOTH `bash %STAGE2%` LINES, not just the student's. The first of them runs as
:: ROOT inside the distro, so a check moved between the two would leave root executing code
:: nothing had verified -- which is exactly what the assertion on this ordering used to miss,
:: because it anchored on the second call. 25-installer.sh pins all three positions now.
"%SYS32%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "%PSHASH%"
if %errorlevel% equ 1 goto digestmismatch
if %errorlevel% neq 0 goto digestunchecked

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
"%SYS32%\wsl.exe" -d %DISTRO% -u root -e env %XENV%CS193V_PROVISION=1 bash %STAGE2%
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
"%SYS32%\wsl.exe" -d %DISTRO% -e env %XENV%CS193V_WINDOWS=1 bash %STAGE2%
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
:: where the difference matters. %SYS32% becomes %SystemRoot%\Sysnative on WOW64, and
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
:: artifacts by the time the create above can move it aside.
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
echo   Rerun the installer and choose Yes when Windows
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
echo   Rerun the installer as yourself, in an ordinary window. If WSL
echo   still has to be turned on, setup will ask for permission for
echo   that one step when it gets there.
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
echo   The likeliest cause left is a WSL older than 2.4.4, which cannot
echo   name a new environment, or the connection dropping mid-download --
echo   but that is a guess, not a diagnosis, and any error above is
echo   worth more.
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
echo   If the network was not up yet inside the environment, rerunning
echo   the installer is enough. If it happens twice, it is something
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
echo   This is usually a network problem, and it is safe to rerun the
echo   installer. Some campus and company networks block
echo   raw.githubusercontent.com outright; if yours does, tell course staff
echo   rather than spending time on it.
echo.
pause
exit /b 1

:: THE WORDING OF :downloadincomplete MOVED HERE (#232), rather than being deleted with the
:: sentinel it belonged to. A cut-short transfer and a wifi sign-in page are still the likeliest
:: things to reach this refusal, so they are still what it names; what is new is the pair of
:: digests, which is the only way a screenshot distinguishes those from a mis-cut release.
:digestmismatch
echo.
echo   The setup script downloaded, but it is not the file this installer
echo   expects, so setup is stopping rather than running it.
echo.
echo   expected: %STAGE2_SHA256%
echo   The number that actually arrived is printed just above.
echo.
echo   That means the transfer was cut short, or something on the network
echo   answered instead of the real thing - a wifi sign-in page, typically.
echo   It is safe to rerun the installer. If it keeps happening, tell course staff.
echo.
pause
exit /b 1

:: AND THE THIRD STATE, WHICH IS NOT A NEGATIVE ANSWER BUT STILL REFUSES. The probe could not ask
:: -- no sha256sum in the distro, or wsl itself failed -- so nothing is known about the file. See
:: %PSHASH% above for why this is the one question whose failure is not allowed to continue.
:digestunchecked
echo.
echo   The setup script downloaded, but this installer could not check it,
echo   so setup is stopping rather than running something unverified.
echo.
echo   It is safe to rerun the installer. If it keeps happening, tell course staff.
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
echo   It is safe to rerun the installer once the problem above is
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
echo   version set it up from scratch, remove it and rerun the installer:
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
echo   It is safe to rerun the installer once the problem is fixed.
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
echo   troubleshooting this yourself, and do not rerun the installer
echo   until it has been sorted out.
echo.
pause
exit /b 1

:nonetwork
:: REACHED FROM ONE PLACE, and only on the road that is about to download 600 MB. Setup waits for
:: the network rather than assuming it, because since #275 this run may have been started by
:: Windows at logon rather than by a student who was sitting there ready -- and at logon the wifi
:: is frequently a few seconds behind the desktop.
::
:: NOTHING HAS BEEN CHANGED, and saying so matters as much as it does at :uacdeclined: the wait is
:: ahead of `wsl --update` and ahead of the create, so a student who lands here has not been left
:: with a half-made environment.
::
:: IT NAMES RUNNING THE FILE AGAIN, AND THAT IS WHAT KEEPS A BOUNDED WAIT FROM BEING A REFUSAL.
:: The probe asks one host over HTTPS; the download asks Microsoft's CDN. Those can disagree, and
:: when they do this arm is wrong about a machine that would have worked. The cost of being wrong
:: therefore has to be one more run and not a dead end -- which is the difference between this and
:: the two virtualisation pre-flights the header records as removed.
::
:: THE CAPTIVE PORTAL IS NAMED because it is the case a student cannot diagnose and course staff
:: cannot fix remotely: campus and hotel networks answer DNS, accept the connection, and then
:: serve a sign-in page, so the computer looks connected and is not.
echo.
echo   Setup could not reach the internet, so it has stopped before
echo   downloading anything. Nothing has been changed.
echo.
echo   If the computer has only just started up, the wifi may still be
echo   connecting -- give it a moment. Then rerun the installer and it
echo   will carry on from here.
echo.
echo   If you are on a network that asks you to sign in through a web
echo   browser, open one and sign in first. Setup cannot answer that
echo   page for you.
echo.
pause
exit /b 1

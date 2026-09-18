# CS193V setup for Windows -- this file is the whole of the line you paste.
#
#     irm <the address on the course website> | iex
#
# WHAT IT DOES, IN FOUR STEPS:
#   1. stops, if this PowerShell session is an administrator's,
#   2. makes the folder %LOCALAPPDATA%\CS193V,
#   3. downloads install-cs193v-windows.cmd into it from GitHub, at the release named below,
#      and checks the bytes that arrived against the SHA-256 written into this file,
#   4. starts it, in this window, and waits for it.
#
# It installs nothing itself and writes nothing anywhere else. Every question you are asked and
# every word you read after the next few lines comes from that .cmd.
#
# WHY THE INSTALLER IS A .cmd AND THIS IS A .ps1, because that looks backwards. A .ps1 SAVED ON
# DISK is refused by the default execution policy -- unsigned and of internet origin -- and has no
# double-click association at all; that is why the installer is not one. Neither reason reaches
# this file. `iex` runs a STRING, and execution policy governs FILES; nothing here is saved, so
# there is no mark of the web to clear either. Both reasons are about a downloaded file and this
# is not one. Both still hold for the 1400-line installer, which stays a .cmd.
#
# 7-BIT ASCII AND NO BYTE-ORDER MARK, AND BOTH ARE MEASUREMENTS. On Windows PowerShell
# 5.1.26100.9444: a leading UTF-8 BOM makes `iex` fail to PARSE, and Invoke-RestMethod decodes a
# response whose Content-Type carries no charset as ISO-8859-1. ASCII is the one encoding under
# which neither can do any harm. 25-installer.sh asserts both and .private/release.sh refuses to
# publish a file that breaks either.
#
# LINE ENDINGS ARE DELIBERATELY NOT PINNED, which is the opposite of the rule for the other two
# published files. Measured on the same host: `iex` parses LF and CRLF identically, inside the
# script block below and outside it, and nothing hashes this file -- so a rule here would assert a
# property nobody can observe. The .cmd's CRLF is load-bearing; see .gitattributes for why.
#
# IT IS SAFE TO PASTE THIS AGAIN. The installer says the same of itself.

& {

# EVERYTHING IS INSIDE THIS SCRIPT BLOCK, FOR TWO MEASURED REASONS, AND NEITHER IS STYLE.
#
# ONE: NOTHING HERE MAY CLOSE YOUR WINDOW. On 5.1.26100.9444, `exit` inside text run by `iex` ends
# powershell.exe ITSELF -- so for a student who opened PowerShell and pasted a line, a refusal
# prints and the window vanishes on the next statement, taking the refusal with it. That is the
# worst possible failure for a message whose whole job is to be read. `return` inside a script
# block returns from the block and nothing else; measured the same day on the same host. So there
# is no `exit` anywhere in this file, and 25-installer.sh keeps it that way. What that costs is
# that this file cannot set its own process exit code; the last line puts the installer's where a
# caller would look for it instead.
#
# TWO: A CUT CONNECTION RUNS NOTHING. The closing brace is the last byte of the file, so any
# truncation leaves it unbalanced and `iex` refuses the whole text before executing any of it.
# Measured by truncating this shape at every byte offset: not one ran anything, LF and CRLF alike.
# `iex` ALONE DOES NOT HAVE THIS PROPERTY -- also measured, a cut that happens to leave valid
# syntax runs the prefix -- so the wrapper provides it, not the cmdlet. This is the one place the
# Windows one-liner is safer than the shell one it copies: `curl | bash` runs every complete line
# of a truncated download.

# ---- what is fetched, and what it has to be ---------------------------------
# FOUR LITERALS, EACH ALONE ON ITS LINE. .private/release.sh rewrites the last two with sed
# anchored at the start of the line, exactly as it rewrites REPO_TAG and PAYLOAD_SHA256 in
# install-cs193v.sh and REPO_TAG and STAGE2_SHA256 in install-cs193v-windows.cmd -- so a composed
# value, or a second assignment above them, would leave the rewrite matching nothing and publish
# the previous release's digest in silence. Everything below is DERIVED from these four, so there
# is no second place for the version or the file name to be written down and go stale.
$RepoOwner = "cs193v"
$RepoName  = "cs193v-container"
$RepoTag   = "release-0.0.0"
$CmdSha256 = "6167db79f2400389c2ff8b6625f5d6e63329e276861100c2658960e385812182"

# FROM GITHUB AND NOT FROM THE COURSE WEBSITE, and that is what keeps the website's address out of
# the repository altogether: this file is the only thing hosted there, and no file in the source
# tree needs to know where "there" is. It is also what makes the digest above a BLOB digest.
# raw.githubusercontent.com serves the stored git object and honours no .gitattributes, so the
# bytes it returns are the bytes `git cat-file blob` gives the release script, whatever the line
# endings in anybody's checkout. install-cs193v-windows.cmd pins stage two from the same host for
# the same reason; this is that idiom one level up.
#
# A TAG AND NOT A BRANCH. Tags are immutable by policy, so the .cmd a student downloads on Monday
# is the .cmd their computer runs after Tuesday's restart, even if a release is cut in between.
$CmdUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoTag/.private/install-cs193v-windows.cmd"

# THE LOCAL NAME CARRIES THE RELEASE, and that is load-bearing rather than tidy. On a machine
# without WSL, setup takes two runs: the first writes a RunOnce entry naming the file it is running
# BY ABSOLUTE PATH, and Windows starts it again at the next sign-in. Under a fixed name, a student
# who pasted a newer release's line in between would overwrite the file that entry names -- and
# possibly while it was running, which cmd.exe cannot survive, because it re-reads a batch file as
# it executes it. Two releases sit here side by side instead.
$Version = $RepoTag -replace '^release-', ''
$CmdName = "install-cs193v-windows-$Version.cmd"

# TWO STAFF OVERRIDES, AND NEITHER IS A PRIVILEGE BOUNDARY. They exist so this file can be pointed
# at a working tree instead of a published release, which is otherwise untestable: there is no
# other way to exercise it against anything but a tag that has already shipped. The same pair
# install-cs193v-windows.cmd carries as CS193V_INSTALLER_URL and CS193V_STAGE2_SHA256, one level
# up, and .private/README.md documents them together. A student never sets either.
if ($env:CS193V_CMD_URL)    { $CmdUrl    = $env:CS193V_CMD_URL }
if ($env:CS193V_CMD_SHA256) { $CmdSha256 = $env:CS193V_CMD_SHA256 }

# ---- and this must not be an administrator's session ------------------------
# ASKED FIRST, BEFORE ANYTHING IS FETCHED OR CREATED, AND IT IS NOT THE AUTHORITY -- the
# installer's own :isadmin is. This only spares an elevated student a download and a folder in the
# wrong profile before being told the same thing. Where the two could disagree they disagree in
# the safe direction: this one lets a run through and :isadmin stops it.
#
# WHY AT ALL (#277): everything setup writes is per-user -- %APPDATA%, %LOCALAPPDATA%, and the
# HKCU key WSL registers environments under, there being no machine-wide registration. A student
# who is not an administrator cannot be elevated as THEMSELVES: UAC asks for somebody else's
# password, and the course is then installed into that account with the student's left empty.
# Measured on Windows 11 26200 on 2026-09-15.
#
# THE SAME QUESTION THE .cmd ASKS, ASKED WITH A CMDLET: can this session READ the LOCAL SERVICE
# hive? Only an elevated process can. A cmdlet rather than reg.exe because `& reg.exe ... 2>$null`
# in 5.1 wraps each stderr line in a NativeCommandError and leaves it in $Error, and because it
# keeps this file's entire external surface at one program.
#
# AND NOT Test-Path, WHICH IS THE OBVIOUS TRANSLATION AND IS WRONG. Measured on 5.1.26100.9444
# from an ordinary session: Test-Path 'Registry::HKEY_USERS\S-1-5-19' returns True. Seeing that the
# key is there needs nothing; READING it is what needs the token.
$elevated = $true
try { $null = Get-ChildItem 'Registry::HKEY_USERS\S-1-5-19' -ErrorAction Stop }
catch { $elevated = $false }
if ($elevated) {
    Write-Host ""
    Write-Host "  Do not run CS193V setup as an administrator."
    Write-Host ""
    Write-Host "  Everything it installs belongs to one Windows account, and an elevated"
    Write-Host "  session need not be yours. Close this window, start PowerShell the"
    Write-Host "  ordinary way, and paste the same line again. Setup asks Windows for"
    Write-Host "  permission by itself for the one step that needs it."
    Write-Host ""
    return
}

# ---- a per-user folder that survives a restart ------------------------------
# %LOCALAPPDATA%\CS193V, WHICH IS ALREADY SETUP'S OWN FOLDER -- install-cs193v-windows.cmd keeps
# cs193v.ico there -- so this is one folder and not two.
#
# AND THE RESTART IS WHY IT IS NOT SOMEWHERE EASIER. The RunOnce entry the installer writes names
# the .cmd by absolute path, so that path has to still resolve after a reboot.
#
# %TEMP% IS EMPTIED OUT OF THE BOX AND DOWNLOADS IS NOT, which is worth stating precisely because
# the opposite is easy to assume. Measured on Windows 11 26200: StorageSense\Parameters\
# StoragePolicy has 01=1 (Storage Sense on) and 04=1 (temp files), and no value at all for 32 or
# 256 -- the Downloads cleanup exists but defaults to Never. So %TEMP% is disqualified outright,
# and Downloads is disqualified for the weaker reasons: an administrator can turn that cleanup
# on, and it is a folder students empty by hand.
#
# %APPDATA% roams, so on a domain profile a 92 KB installer would be copied across the network at
# every sign-in. %ProgramData% is machine-wide and needs an administrator, which is the one thing
# setup refuses to be. Local AppData is where Windows programs put per-user files that are theirs
# and are not worth roaming.
#
# -LiteralPath WHEREVER THE PARAMETER EXISTS: this path contains the account name, and square
# brackets are legal in one and are wildcards to -Path.
#
# -Force IS THE IDEMPOTENT FORM -- it creates the folder when it is absent and says nothing when it
# is not. `$null =` rather than a pipe to Out-Null; there are no pipes anywhere in this file.
#
# AND THE VARIABLE IS CHECKED BEFORE IT IS USED, although a real session always sets it.
# Measured on 5.1.26100.9444 with it emptied: Join-Path throws a
# ParameterBindingValidationException that escapes the try below -- because the try starts one
# line too late -- and reaches the student as a raw .NET type name. That is the single outcome
# this file exists to prevent, so the one line that assumes an environment variable says so.
if (-not $env:LOCALAPPDATA) {
    Write-Host ""
    Write-Host "  Windows did not say where your application data folder is, so there"
    Write-Host "  is nowhere to put the installer and nothing has run. Send course"
    Write-Host "  staff this window."
    Write-Host ""
    return
}
$dir = Join-Path $env:LOCALAPPDATA "CS193V"
try { $null = New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop }
catch {
    Write-Host ""
    Write-Host "  Setup could not create the folder it works in, so nothing has run:"
    Write-Host "      $dir"
    Write-Host ""
    return
}

# ---- fetch it, and check what arrived ---------------------------------------
# TO A TEMPORARY NAME FIRST, so that a failed or interrupted download cannot leave anything at the
# real name for a later run -- or for the RunOnce entry -- to find and trust. The real name only
# ever appears once the bytes behind it have been checked.
#
# -UseBasicParsing AND $ProgressPreference, the two idioms the .cmd's own %PSNETWAIT% already
# carries: without the first, 5.1 hands the body to the Internet Explorer engine, which on a fresh
# profile is not initialised and throws; the second stops a progress bar that draws over the
# console and costs more wall clock than the transfer does.
#
# Invoke-WebRequest AND NOT curl.exe, although curl.exe has shipped in System32 since Windows 10
# 1803 and would save the conversion below. curl does not read Windows' WPAD/PAC proxy
# configuration and Invoke-WebRequest does, so on a campus or managed laptop this can reach a host
# curl cannot -- and the same stack has already proved the network works against this exact host,
# because it is how this file arrived.
$tmp = Join-Path $dir "install-cs193v-windows.download"
$ProgressPreference = "SilentlyContinue"
Write-Host ""
Write-Host "  Downloading CS193V setup:"
Write-Host "      $CmdUrl"
try { Invoke-WebRequest -UseBasicParsing -Uri $CmdUrl -OutFile $tmp -ErrorAction Stop }
catch {
    Write-Host ""
    Write-Host "  That download did not finish, so nothing has run. Check the internet"
    Write-Host "  connection and paste the same line again."
    Write-Host ""
    return
}

# THE FIRST OF THREE LINKS. This file pins the .cmd; the .cmd pins install-cs193v.sh with
# STAGE2_SHA256; that script pins the course tree with PAYLOAD_SHA256. Only this file is unchecked.
#
# -ne AND NOT -cne, AND THAT IS LOAD-BEARING. PowerShell's -ne on strings is case-INSENSITIVE,
# Get-FileHash returns UPPER-case hex, and every digest this project publishes is lower-case.
# Measured on 5.1.26100.9444. -cne here would refuse every correct download.
#
# IT PRINTS BOTH NUMBERS, for the reason the .cmd's own digest probe does: a cut-short transfer and
# a mis-cut release arrive here looking identical, and only the digests say which -- so a student's
# screenshot carries the answer instead of staff guessing at it.
$have = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
if ($have -ne $CmdSha256) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "  The file that arrived is not the one this line expects, so nothing"
    Write-Host "  has been run."
    Write-Host "      expected  $CmdSha256"
    Write-Host "      received  $($have.ToLower())"
    Write-Host ""
    Write-Host "  If this network has a sign-in page, sign in first and paste the same"
    Write-Host "  line again."
    Write-Host ""
    return
}

# ---- LF to CRLF, which cmd.exe needs and git does not store -----------------
# CHECKED FIRST, CONVERTED SECOND, AND THE ORDER IS THE WHOLE OF IT. The digest above is of the
# bytes GitHub sent. Converting before checking would hash something GitHub never served, and the
# pin would then be a number nobody could reproduce.
#
# WHY A CONVERSION AT ALL: .gitattributes marks the .cmd `text eol=crlf`, so git STORES it with LF
# endings and only a checkout has CRLF -- and raw.githubusercontent.com serves the stored object.
# CRLF is not cosmetic for a batch file: cmd.exe reads one in 512-byte chunks and its label scanner
# assumes a two-byte terminator, so under LF endings goto and call fail depending on the byte
# offset of the label, and that installer is entirely goto-structured.
#
# NORMALISE, THEN CONVERT, so the transform is idempotent and stays correct if the served bytes
# ever already carry CRLF. A single newline-to-CRLF replace over CRLF input yields a doubled CR.
#
# ASCII IS SAFE HERE because the .cmd is ASCII-only and the test suite enforces it -- batch is
# decoded as OEM with no UTF-8 support, so it could not hold anything else. [Text.Encoding]::UTF8
# would be the wrong choice for a different reason: in .NET Framework it emits a byte-order mark.
$text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($tmp))
$text = ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
$cmd  = Join-Path $dir $CmdName
[IO.File]::WriteAllText($cmd, $text, [Text.Encoding]::ASCII)
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

# ---- start it, in this window -----------------------------------------------
# THE PATH IS SAID OUT LOUD because the installer refers to itself: several of its messages say it
# is safe to rerun setup, and this is where setup now lives.
Write-Host ""
Write-Host "  Starting setup. It is at"
Write-Host "      $cmd"
Write-Host ""

# cmd.exe AND NOT THE .cmd DIRECTLY: a batch file is not an executable and something has to name
# the interpreter -- the same reason the RunOnce value the installer writes begins with cmd.exe.
# Named through $env:SystemRoot because Windows need not be installed on C: and the directory need
# not be called Windows, which is issue #125's rule; this file keeps it although cmd.exe is the
# only program it has to keep it for.
#
# ONE -ArgumentList STRING, WHICH IS THE ONLY FORM THAT SURVIVES A REAL PROFILE. Letting .NET build
# the command line from separate arguments quotes one containing WHITESPACE and not one containing
# an ampersand -- so an account called `Tom & Jerry` works and one called `Tom&Jerry` has its
# command line split by cmd at the ampersand. A single string reaches CreateProcess verbatim.
# %PSELEV% in the .cmd builds its elevated child's line the same way.
#
# /s IS THE OTHER HALF. Without it, `cmd /c "path"` keeps the outer quotes only when the text has
# whitespace AND none of & ^ ( ), and strips them otherwise. With /s cmd removes exactly the first
# and last quote and runs the rest verbatim, which is the same answer for every path.
#
# -NoNewWindow SO IT TALKS TO THIS CONSOLE. Setup prints for several minutes and stops at seventeen
# pauses waiting for a key; a second window would take that conversation somewhere the student is
# not looking. `irm | iex` does not redirect stdin -- measured -- so the keyboard the .cmd reads is
# the real one, exactly as it is when the file is started by hand.
$p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/s /c "' + $cmd + '"') -NoNewWindow -Wait -PassThru

# THE ONLY THING THIS FILE WRITES OUTSIDE ITS OWN SCOPE, and it is here because the alternative is
# `exit`, which would close the window. A caller that wants setup's answer finds it where a caller
# looks; nothing in the course reads it, and a student never needs to.
$global:LASTEXITCODE = $p.ExitCode

}

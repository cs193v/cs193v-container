-- CS193V Development Environment -- the macOS entry point (#134)
--
-- Compiled by .private/macapp/make-macapp.sh into an applet, at AUTHORING time on a staff Mac,
-- and the result is committed. It is NOT built on a student's machine: `codesign` cannot sign
-- without the Command Line Tools (/usr/bin/codesign_allocate is a CLT shim), so a bundle built
-- there could not be re-sealed after its Info.plist was written.
--
-- WHY AN APPLET AND NOT A SHELL SCRIPT IN Contents/MacOS. Two measured defects of that shape:
-- Launch Services cannot read an architecture out of a script, so Apple Silicon offers Rosetta;
-- and TCC attributes the Automation grant to the INTERPRETER, so the grant landed on /bin/sh --
-- meaning every shell script the student ever ran gained permission to control Terminal, and
-- the usage string was never shown because the prompt did not name this app. A compiled applet
-- is a real universal Mach-O with a real identity, which fixes both.
--
-- THE COURSE DIRECTORY IS READ FROM OUTSIDE THE BUNDLE. Writing anything inside would break the
-- ad-hoc seal, and a bundle that fails `codesign -v` has a damaged identity -- which is the one
-- thing this applet exists to have. The installer records it instead.
--
-- @@ placeholders are substituted by make-macapp.sh from the message catalogue, so student
-- facing prose stays in course-install-messages.txt and is not duplicated here.

on run
	set supportPath to (POSIX path of (path to library folder from user domain)) & "Application Support/CS193V/course-dir"

	-- Where did the installer say the course files are? No record means no install.
	set courseDir to ""
	try
		set courseDir to do shell script "cat " & quoted form of supportPath
	end try
	if courseDir is "" then
		display alert "@@LABEL@@" message "@@NOT_INSTALLED@@" as critical
		return
	end if

	-- The helper lives in our own Resources, so its path is ours rather than student input.
	set helperPath to (POSIX path of (path to me)) & "Contents/Resources/cs193v-run"

	-- One fifo per launch. `mktemp -u` then `mkfifo` refuses to follow a symlink or clobber an
	-- existing file, and $TMPDIR is per-user and mode 700 on macOS.
	set fifoPath to do shell script "F=$(mktemp -u \"${TMPDIR:-/tmp}/cs193v-win.XXXXXX\"); mkfifo \"$F\"; printf %s \"$F\""

	-- Type the helper into a NEW Terminal tab. `do script` types at a fresh interactive login
	-- shell, so the launcher ends up a foreground JOB in its own process group and `login` stays
	-- the session leader -- the shape measured clean, and not the session-leader shape #170 is
	-- about. `cd dir; cmd arg arg` is a form every shell macOS ships parses alike;
	-- `exec 9>...` typed here would be read by tcsh as "run a command named 9".
	--
	-- WHY IT `cd`s FIRST, WHEN THE HELPER ALREADY DOES. The helper's own `cd` is in a CHILD
	-- process, so the interactive shell never moves -- and on a refusal the student is left at a
	-- prompt in $HOME, reading launcher advice that says `./cs193v --stop`. messages.txt says
	-- that in twelve places, all correct for a student who typed `cd DIR && ./cs193v` by hand and
	-- all wrong for a tab we opened. Landing the shell where the documented path would have put
	-- it fixes every one of them at once; rewording twelve messages would not, since they are
	-- right for the manual path.
	--
	-- `;` NOT `&&`: if the cd fails the helper must still run, because the helper's
	-- `cd "$1" || exit 1` is the authority and it reports the failure. With `&&` a bad directory
	-- would leave a silent shell and no message at all.
	set windowId to 0
	try
		tell application "Terminal"
			activate
			set theTab to do script ("cd " & quoted form of courseDir & "; " & quoted form of helperPath & " " & quoted form of courseDir & " " & quoted form of fifoPath)
			set windowId to id of (first window whose tabs contains theTab)
		end tell
	on error
		do shell script "rm -f " & quoted form of fifoPath
		display alert "@@LABEL@@" message "@@LAUNCH_FAILED@@" as critical
		return
	end try

	-- BLOCK until the helper signals. Not a poll: the kernel wakes us. `read` returns either the
	-- sentinel (launcher exited 0) or EOF with nothing (it failed, or the window died).
	set verdict to ""
	try
		set verdict to do shell script "read -r v < " & quoted form of fifoPath & " || true; printf %s \"$v\""
	end try
	do shell script "rm -f " & quoted form of fifoPath

	-- Close ONLY on success, so a refusal stays on screen to be read.
	if verdict is "ok" then
		try
			with timeout of 10 seconds
				tell application "Terminal" to close (first window whose id is windowId)
			end timeout
		end try
	end if
end run

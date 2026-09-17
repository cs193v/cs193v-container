/* powershell.exe, for the -Command strings the installer runs. TWO PROBES AND TWO COMMANDS.
 *
 * THE SPLIT MATTERS MORE THAN THE COUNT. The two probes ANSWER a question -- their whole output
 * is an exit code the .cmd branches on. The two commands (#134) DO something: they write and
 * remove Start Menu entries, and what a case asserts on is the files that are there afterwards,
 * not a code. They arrived without a fake, which is #270; the arms at the bottom say what that
 * cost.
 *
 * WHY IT DISPATCHES ON THE COMMAND TEXT. This fake once answered the only question the installer
 * asked -- does the CS193V distro exist -- so it needed no idea which question it was being asked.
 * Issue #112 added three more, and a fake that answered them all from one knob would let a case
 * arrange a self-contradictory machine. So the marker is read off the -Command text, which is the
 * .cmd's OWN string -- an installer that stops asking one of these stops matching here, rather
 * than silently getting the previous answer.
 *
 * THE FOUR THAT WERE HERE ARE ALL GONE, over two issues, and the reason is worth keeping because
 * this file is part of how the second one got shipped. Three of them asked WHICH cause stopped a
 * VM from starting -- HypervisorPresent, then VirtualMachinePlatform, then hypervisorlaunchtype.
 * #114 is a VirtualBox guest where the first reads TRUE, because a hypervisor genuinely is
 * present, just not one WSL2 can build a VM with. The fourth replaced all three by importing a
 * throwaway distro and asking whether it registered -- and that could never answer yes, because
 * `wsl --import` validates the rootfs before registering and the payload was an empty directory.
 *
 * A COMMENT HERE ASSERTED THE FIRST OF THOSE MISTAKES IN PROSE: it said HypervisorPresent was
 * "false for every cause" of HCS_E_HYPERV_NOT_INSTALLED. It was not. A fixture that agrees with
 * the installer's reasoning cannot contradict it, which is why neither defect went red -- and the
 * import gate then repeated the pattern one commit later, with an --import arm that accepted any
 * payload it was handed. Both are recorded in .private/README.md.
 *
 * WHAT IS LEFT ASKS ABOUT WSL, NOT ABOUT THE MACHINE. One probe reads the distro list; the other
 * reads what `wsl --status` SAID, and only after something has already failed. Neither infers a
 * capability from a property.
 *
 * AN UNRECOGNISED PROBE IS A HARNESS FAILURE, not a "no". exit 120 is the same code fake_say uses
 * for a missing message key, and for the same reason: a fake that guessed 1 would report every new
 * probe as a negative answer, and the case asserting on that negative would pass.
 *
 * BOTH PROBES ANSWER FROM SHARED STATE rather than from a knob of their own -- the distro list
 * fake-wsl.c maintains, and the same wsl.status.novirt knob its --status arm prints from. So a
 * case cannot arrange a machine that contradicts itself, which is what a per-probe knob would let
 * it do.
 *
 * Exit codes follow the real -Command contract: the answer arrives AS a code, 0 or 1. Anything
 * else means the probe itself could not run (powershell absent gives cmd's 9009), which is a
 * different thing from "absent" -- the installer has a separate arm for each, so the fake needs a
 * way to produce it. `ps.rc` forces EVERY probe, which is what "powershell is missing" looks like;
 * the per-probe `ps.*.rc` knobs force one at a time.
 */
#include "win-fake.h"

/* Does any argument contain this text? The markers below are substrings of the .cmd's own
 * PowerShell, so this is deliberately not an exact match on the whole command line. */
static int mentions(int argc, char **argv, const char *needle) {
    for (int i = 1; i < argc; i++) if (strstr(argv[i], needle)) return 1;
    return 0;
}

/* ─── reading the .cmd's OWN paths back out of its -Command text  (#270) ───────
 *
 * EVERY PATH THESE TWO ARMS TOUCH IS PARSED OUT OF THE COMMAND, AND NONE COMES FROM A KNOB.
 * That is the property, not an implementation detail. A knob would mean the fixture deciding
 * which directory is the Start Menu and the .cmd's own answer never being consulted -- which is
 * what the two static assertions in 25-installer.sh were doing, and why a delete aimed at a
 * folder WSL never writes to stayed green for the length of a release.
 *
 * SINGLE QUOTES, BECAUSE THAT IS WHAT BATCH CAN PASS. The .cmd hands PowerShell one
 * double-quoted argument, so every path inside it is single-quoted; there is no escaping to
 * handle and no case where a path legitimately contains one.
 *
 * THE PREFIX INCLUDES THE OPENING QUOTE AND WHATEVER IS BETWEEN, so a caller spells out what it
 * is looking for. The two shapes in this .cmd are `$s.TargetPath = '...'` and `-match '...'`;
 * composing " = '" here instead would have quietly failed to find the second, which is the one
 * the guard turns on. */
static int quoted_after(int argc, char **argv, const char *prefix, char *out, size_t n) {
    for (int i = 1; i < argc; i++) {
        const char *a = strstr(argv[i], prefix);
        const char *b;
        if (!a) continue;
        a += strlen(prefix);
        if (!(b = strchr(a, '\''))) continue;
        if ((size_t)(b - a) >= n) return 0;
        memcpy(out, a, (size_t)(b - a));
        out[b - a] = '\0';
        return 1;
    }
    return 0;
}

/* Every single-quoted literal ending in .lnk, in the order the command names them. The delete
 * checks more than one path, so this returns all of them rather than the first: a .cmd that
 * looked only in the wrong place would yield one entry here and find nothing at it. */
#define PS_MAX_LNK 8
static int lnk_literals(int argc, char **argv, char lits[][512]) {
    int count = 0;
    for (int i = 1; i < argc && count < PS_MAX_LNK; i++) {
        const char *s = argv[i];
        while (count < PS_MAX_LNK) {
            const char *a = strchr(s, '\'');
            const char *b;
            size_t len;
            if (!a || !(b = strchr(a + 1, '\''))) break;
            len = (size_t)(b - a - 1);
            if (len > 4 && len < 512) {
                char buf[512];
                memcpy(buf, a + 1, len);
                buf[len] = '\0';
                if (fake_contains_ci(buf + len - 4, ".lnk"))
                    snprintf(lits[count++], 512, "%s", buf);
            }
            s = b + 1;
        }
    }
    return count;
}

/* -1 is not a plausible answer to a yes/no question, so it doubles as "unset" for every rc knob.
 * `forced` is consulted before the answer is computed, and the GLOBAL knob wins: a machine with
 * no powershell cannot answer one question and fail another. */
/* PRESENCE DECIDES WHETHER A KNOB IS SET, NOT THE SIGN OF ITS VALUE, and that is a fix rather than
 * a preference. This used to read `fake_knob_int(rcknob, -1)` and act on `forced >= 0`, which made
 * -1 the sentinel for "absent" -- so `ps.elev.rc -1` was indistinguishable from never setting it.
 * fake-wsl.c's answer() has always disagreed: it takes `fake_knob_int(rcknob, dfltrc)` straight, so
 * `wsl.status.rc -1` is honoured, and -1 is the DOCUMENTED value there because it is what wsl.exe
 * really returns. One convention, two behaviours, no warning at either site.
 *
 * MEASURED THE HARD WAY while adding win-elevfailed: the case set `ps.elev.rc -1` to arrange a
 * failing elevation, the fake answered 0, and the installer printed the restart notice -- a case
 * that looked like it arranged a failure and arranged nothing, and would have gone green saying so.
 * Reading the knob's PRESENCE removes the sentinel altogether, so a negative code now means what it
 * says and the two fakes agree. Checked before changing it: every ps.* knob in the suite is set to
 * a non-negative value, so nothing depended on the old reading. */
static int answer(const char *rcknob, int value) {
    char raw[64];
    if (fake_knob("ps.rc", raw, sizeof raw) && raw[0]) return (int)strtol(raw, NULL, 10);
    if (fake_knob(rcknob, raw, sizeof raw) && raw[0]) return (int)strtol(raw, NULL, 10);
    return value;
}

/* Is NAME in the list fake-wsl.c maintains? Reading the same file the --install arm appends to is
 * what makes the .cmd's probe/create/re-probe sequence behave the way it would on a machine. */
static int listed(const char *name) {
    char p[1024], line[512];
    fake_path(p, sizeof p, "wsl.list");
    FILE *f = fopen(p, "rb");
    if (!f) return 0;                       /* nothing registered -> absent */
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
        /* the real probes anchor with -match '^NAME$', so CS193V-old must not match CS193V */
        if (n && strcmp(line, name) == 0) { found = 1; break; }
    }
    fclose(f);
    return found;
}

/* Are two files in the case directory byte-identical? Used by the digest arm below to check that
 * what the curl arm actually WROTE is the body the harness prepared and hashed. */
static int same_bytes(const char *a, const char *b) {
    char pa[1024], pb[1024];
    unsigned char ba[4096], bb[4096];
    FILE *fa, *fb;
    size_t na, nb;
    int same = 1;
    fake_path(pa, sizeof pa, a);
    fake_path(pb, sizeof pb, b);
    if (!(fa = fopen(pa, "rb"))) return 0;
    if (!(fb = fopen(pb, "rb"))) { fclose(fa); return 0; }
    do {
        na = fread(ba, 1, sizeof ba, fa);
        nb = fread(bb, 1, sizeof bb, fb);
        if (na != nb || memcmp(ba, bb, na) != 0) { same = 0; break; }
    } while (na > 0);
    fclose(fa);
    fclose(fb);
    return same;
}

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);

    const char *distro = getenv("CS193V_FAKE_DISTRO");
    if (!distro) distro = "CS193V";

    /* ─── THE ENTRY THAT RESUMES SETUP AFTER THE RESTART  (#275) ──────────────
     *
     * DISPATCHED FIRST, AND THAT IS A CORRECTNESS REQUIREMENT RATHER THAN A PREFERENCE.
     * `Remove-ItemProperty` CONTAINS `Remove-Item`, which the Start Menu delete arm at the bottom
     * of this file dispatches on -- so a clear that reached that arm would be read as a shortcut
     * delete. It would find no .lnk literal and return 120, which a case would read as a failed
     * clear; and a future clear that happened to carry a path would have that shortcut REMOVED.
     * The arms below already state the rule twice ("two commands sharing a substring must be
     * dispatched on the one that distinguishes them"); this is the third instance and the only
     * one where the shared text is a strict prefix of the other command's marker, which is the
     * case no amount of care at the other end catches.
     *
     * THE STORE IS A FILE AND NOT A KNOB, for the reason fake-wsl.c keeps `wsl.list` in one: the
     * .cmd writes this value, reads it back, and clears it, and those three have to agree with
     * each other rather than with three separate arrangements a case typed out.
     *
     * AND THE VALUE IS READ OUT OF THE ENVIRONMENT, NOT COMPOSED HERE. %RESUMECMD% is built in
     * batch and handed over as $env:RESUMECMD precisely so this fake can record what the
     * installer DECIDED. A fake that assembled the expected command line itself, out of
     * %SystemRoot% and the script path, would agree with the installer's reasoning and could
     * therefore never contradict it -- which is exactly how #270 survived a release.
     *
     * WHAT IT DOES NOT MODEL: the read-back inside %PSRESUME% is not replayed. On a real machine
     * a write that did not take is indistinguishable here from one that did, so the fake models
     * the OUTCOME -- `ps.runonce.rc` non-zero means the value is not there afterwards, and the
     * store is left absent so the machine cannot contradict itself. That the .cmd reads its own
     * write back at all is asserted in 25-installer.sh, as text. */
    if (mentions(argc, argv, "RunOnce")) {
        char store[1024];
        fake_path(store, sizeof store, "runonce");
        if (mentions(argc, argv, "Remove-ItemProperty")) {
            char raw[64];
            /* THE FORCED CODE IS CONSULTED BEFORE THE REMOVAL, the same way the write arm below
             * consults it before writing. A case arranging "the registry refused this" has to get
             * a prefix where the value is STILL THERE, not one where it is gone and the .cmd was
             * told otherwise -- the machine a case arranges must not contradict itself, which is
             * the rule the two probes at the top of this file were given shared state for.
             * Read by PRESENCE and not by sign, which is #278, and the blanket ps.rc still wins.
             *
             * A CLEAR THAT FOUND NOTHING EXITS NON-ZERO, AND THAT IS A MEASUREMENT RATHER THAN A
             * GUESS. Measured on Windows PowerShell 5.1.26100.9444 on 2026-09-16:
             * `Remove-ItemProperty -ErrorAction SilentlyContinue` on a value that is not there
             * exits 1 -- SilentlyContinue suppresses the MESSAGE, not the failure, and
             * powershell.exe -Command reports it. Removing a value that IS there exits 0.
             *
             * WHICH MEANS THE ORDINARY RUN GETS A 1. :havewsl clears the entry on every run and
             * almost every run has nothing to clear, so an honest fake returns the awkward code
             * here rather than the tidy one. The .cmd waives that exit deliberately; if the
             * waiver is ever removed, this arm is what turns the tier red on the common path,
             * which is the point of modelling it. A fake returning 0 would have let that change
             * look correct. */
            if ((fake_knob("ps.rc", raw, sizeof raw) && raw[0]) ||
                (fake_knob("ps.runonce.rc", raw, sizeof raw) && raw[0]))
                return (int)strtol(raw, NULL, 10);
            return remove(store) == 0 ? 0 : 1;
        }
        if (mentions(argc, argv, "Set-ItemProperty")) {
            /* THE FORCED FAILURE IS DECIDED BEFORE THE WRITE, so a case arranging "the registry
             * refused this" gets a prefix with no entry in it, and not one holding a value the
             * .cmd was told it had failed to store. */
            int rc = answer("ps.runonce.rc", 0);
            if (rc != 0) return rc;
            const char *v = getenv("RESUMECMD");
            /* A write carrying nothing is a HARNESS failure and not an empty value. The .cmd
             * passes the command line in the environment; an installer that stopped doing so
             * would otherwise register an empty entry here and every assertion about the entry
             * EXISTING would still pass. */
            if (!v || !*v) {
                fprintf(stderr, "win-fake: the resume write carried no RESUMECMD\n");
                return 120;
            }
            FILE *f = fopen(store, "wb");
            if (!f) {
                fprintf(stderr, "win-fake: could not write %s\n", store);
                return 1;
            }
            fputs(v, f); fputc('\n', f);
            fclose(f);
            return 0;
        }
        fprintf(stderr, "win-fake: unrecognised RunOnce operation: %s\n",
                argc > 1 ? argv[argc-1] : "(no arguments)");
        return 120;
    }

    /* ─── WAITING FOR A NETWORK BEFORE THE 600 MB DOWNLOAD  (#275) ─────────────
     *
     * ANSWERED INSTANTLY, AND THE LOOP IS THEREFORE EXERCISED BY NO TIER AT ALL. wine_run gives
     * the container --network=none, and no case may pay two minutes of wall clock, so what this
     * arm models is the .cmd's BRANCH on reachable-or-not and nothing whatever about the retry.
     * The deadline, the attempt floor and the gap between tries are held by 25-installer.sh
     * reading %PSNETWAIT% as text, and by a MANUAL.md row that pulls a real network mid-probe.
     * Stated here because an arm that returns 0 in a microsecond looks like it tested the wait,
     * and the next person to weaken the loop will look at this file first. */
    if (mentions(argc, argv, "Invoke-WebRequest"))
        return answer("ps.netwait.rc", fake_knob_int("net.reachable", 1) ? 0 : 1);

    /* DID WINDOWS BLAME VIRTUALISATION? The .cmd asks this only after a create or a `-d` call has
     * already failed, to choose between :novm and a refusal that names no cause. It answers from
     * the same wsl.status.novirt knob fake-wsl.c's --status arm prints from, so a case cannot
     * arrange a machine whose --status says one thing and whose classifier says another.
     *
     * TESTED BEFORE THE DISTRO PROBE, because both commands set WSL_UTF8 and that substring would
     * match either. The distinctive token is the URL the .cmd greps for, which is the same reason
     * the retired gate's probe had to be ordered first: two probes that differ only in their
     * needle must be dispatched on the needle. */
    if (mentions(argc, argv, "aka.ms/enablevirtualization"))
        return answer("ps.vmfail.rc", fake_knob_int("wsl.status.novirt", 0) ? 0 : 1);

    /* ASKING WINDOWS FOR PERMISSION TO TURN WSL ON. The .cmd reaches this only when WSL is
     * absent, and it is the single elevation request in the file -- one child running
     * `wsl --update & wsl --install --no-distribution`, whose exit code is the only thing that
     * comes back. See install-cs193v-windows.cmd's %PSELEV% for why no output can.
     *
     * DISPATCHED ON Start-Process, which no other command here uses. It shares `--no-distribution`
     * with nothing and `WSL_UTF8` with nothing, but it is tested BEFORE the distro probe anyway,
     * for the reason the two arms above state: order is how this file stays honest about which
     * command it is answering, and a needle added to %PSELEV% later must not silently land on a
     * probe that happens to match.
     *
     * WHAT THIS CANNOT MODEL, AND IT IS THE TIER'S LIMIT HERE. The child never runs: under wine
     * there is no elevation and no AppInfo service, so the two wsl.exe calls inside it are never
     * made and never logged. So a case can drive what the .cmd DOES with each answer -- carry on,
     * refuse a declined prompt, refuse a failure -- and cannot see what the child did. That the
     * child carries BOTH commands, and joins them with `&` rather than `&&`, is asserted
     * statically in 25-installer.sh instead (windows:the-child-updates-wsl and its siblings).
     * A fake that re-implemented the child's two calls would be this file agreeing with the
     * installer's own reasoning, which is what let #270 survive a release.
     *
     * THREE ANSWERS, MATCHING THE .cmd's CONTRACT. 0 the child ran and succeeded; 101 the prompt
     * was declined, which is a person and not a broken machine; anything else a failure. 101 is
     * its own knob rather than a value of ps.elev.rc, so a case reads as the machine it is
     * arranging -- `wine_knob win.uac-declined 1` -- and not as a number. */
    if (mentions(argc, argv, "Start-Process")) {
        /* CAN THE CHILD'S PROGRAM EVEN RUN? This is the one thing about the child the fake CAN
         * know, and it has to answer it or the fixture contradicts the machine: with
         * system32\wsl.exe deleted -- harness.no-wsl-exe, which is a real deletion in the prefix
         * and not a knob -- cmd.exe would fail to start the program and return non-zero, so the
         * .cmd must reach :wslfeaturefailed. Answering 0 from a knob regardless would have this
         * file telling a student to restart a machine whose wsl.exe is gone, which Microsoft
         * treats as unrepairable short of an in-place upgrade.
         *
         * CHECKED ON DISK RATHER THAN BY READING THE MARKER the harness writes: the marker is
         * harness bookkeeping, the binary is the fact. */
        char wslexe[1024];
        const char *root = getenv("SystemRoot");
        FILE *probe;
        snprintf(wslexe, sizeof wslexe, "%s\\system32\\wsl.exe", root ? root : "C:\\windows");
        if (!(probe = fopen(wslexe, "rb")))
            return answer("ps.elev.rc", 102);
        fclose(probe);
        return answer("ps.elev.rc", fake_knob_int("win.uac-declined", 0) ? 101 : 0);
    }

    /* ─── THE STAGE-TWO DIGEST  (#232) ────────────────────────────────────────
     *
     * DISPATCHED ABOVE THE WSL_UTF8 ARM, AND THAT IS A CORRECTNESS REQUIREMENT. Every probe in
     * the .cmd opens with `$env:WSL_UTF8=1`, including this one -- so the distro-list arm below
     * would answer the digest question first and return `listed(distro) ? 0 : 1`, i.e. "the
     * digests match" on every case where the distro exists. That is the third instance of the
     * rule this file states twice already: two commands sharing a substring must be dispatched on
     * the one that DISTINGUISHES them. `sha256sum` appears in no other probe.
     *
     * NO SHA-256 IN THIS FILE, AND THAT IS THE POINT. The harness writes the body it wants served
     * as stage2.src and writes its digest beside it, with real sha256sum -- so the number this
     * arm judges by was computed by coreutils and not by ~130 lines of hand-rolled C in a mingw
     * PE with no -Werror. What is compared is the expectation THE .cmd SUPPLIED against that
     * number, which is the same shape as the grep arm this replaces: fake-wsl.c ignored the FILE
     * it was handed and judged the PATTERN, because the pattern was the installer's own.
     *
     * AND IT IS NOT TAUTOLOGICAL, which is the thing to check before believing any of that. A
     * .cmd carrying a wrong constant fails here; one whose batch expansion of %STAGE2_SHA256%
     * went missing fails here; a truncated or byte-altered body fails here, because the harness
     * hashed the body it served rather than the body it wished it had served. What this cannot
     * catch is a probe that hashes the wrong PATH -- the fakes ignore paths by design, on both
     * sides -- so 25-installer.sh asserts that statically instead.
     *
     * THE EXPECTATION COMES OUT OF THE COMMAND LINE, with quoted_after(), for the reason that
     * function's own header gives: a knob would mean the fixture deciding the answer and the
     * .cmd's own value never being consulted.
     *
     * 2 AND NOT 1 WHEN THERE IS NOTHING TO HASH. The .cmd distinguishes "the digests differ" from
     * "the question could not be asked" and refuses differently for each, so a missing download
     * has to produce the second -- which is also what a real `wsl -e sha256sum` on an absent file
     * would do.
     *
     * exit 120 FOR A PROBE THIS FILE CANNOT READ, per the header: a fake that guessed would
     * report a harness defect as a student-visible answer. */
    if (mentions(argc, argv, "sha256sum")) {
        char want[128], truth[128];
        if (!fake_exists("stage2.sh")) return 2;
        if (!quoted_after(argc, argv, "-eq '", want, sizeof want)) {
            fprintf(stderr, "win-fake: the digest probe carries no single-quoted expectation\n");
            return 120;
        }
        if (!fake_knob("stage2.sha256", truth, sizeof truth) || !truth[0]) {
            fprintf(stderr, "win-fake: no stage2.sha256 beside stage2.src in the case\n");
            return 120;
        }
        if (same_bytes("stage2.sh", "stage2.src") && strcmp(want, truth) == 0) return 0;
        /* AND IT ECHOES WHAT ARRIVED, IN THE .cmd's OWN WORDS. The real probe prints the digest it
         * computed, because the batch side has no way to learn it -- so a fixture that returned
         * only the code would leave the refusal naming one number where the file promises two, and
         * the case asserting on that would have nothing to find.
         *
         * THE LABEL IS PARSED OUT OF THE COMMAND, not spelled here, which is the same discipline
         * the expectation above follows and win-fake.h's "no prose lives in these programs" asks
         * for. `Write-Host ('  received: ' + $h)` puts the wording in a single-quoted literal, so
         * quoted_after() reads it back -- and a .cmd that stopped printing it at all yields no
         * label, this prints nothing, and the assertion goes red rather than passing on a fixture
         * that had invented the sentence. */
        char label[128];
        if (quoted_after(argc, argv, "Write-Host ('", label, sizeof label))
            printf("%s%s\n", label, truth);
        return 1;
    }

    /* Does the CS193V distro exist? WSL_UTF8 is the marker because batch cannot read wsl.exe's
     * UTF-16, which is the whole reason this probe goes through PowerShell at all. */
    if (mentions(argc, argv, "WSL_UTF8"))
        return answer("ps.distro.rc", listed(distro) ? 0 : 1);

    /* ─── AND TWO COMMANDS THAT ARE NOT PROBES AT ALL  (#134, #270) ────────────
     *
     * NEITHER OF THESE EXISTED HERE UNTIL #270, and what that cost is worth recording. #134
     * added both PowerShell calls to the .cmd and touched neither this file nor
     * 27-installer-windows.sh, so both landed on the refusal below and returned 120 -- and the
     * .cmd checks PSLNK's code, so every wine case would have taken :shortcutfailed. It did not
     * even get that far: the icon copy above it reads a \\wsl.localhost path, wine does not
     * implement UNC, and `copy` failed first. The whole Start Menu block was unreachable in a
     * tier reporting 213 green, with the one red assertion (win-ok:no-stderr-noise, on `Path
     * not found.`) reading like noise rather than like a block nothing entered.
     *
     * REMOVE-ITEM IS TESTED FIRST, AND THE ORDER IS LOAD-BEARING. PSDEL contains CreateShortcut
     * too -- it opens the entry to read its target before deciding -- so dispatching on
     * CreateShortcut first would send the delete to the create arm and quietly rewrite the very
     * file it was asked to remove. Same rule the aka.ms arm above states: two commands sharing a
     * substring must be dispatched on the one that distinguishes them. */
    if (mentions(argc, argv, "Remove-Item")) {
        char lits[PS_MAX_LNK][512];
        int n = lnk_literals(argc, argv, lits), i;
        /* A delete that names no path is a harness failure, not a delete with nothing to do:
         * without this, a .cmd whose %SMDIR% went empty would remove nothing and look correct. */
        if (n == 0) {
            fprintf(stderr, "win-fake: the delete named no .lnk path: %s\n",
                    argc > 1 ? argv[argc-1] : "(no arguments)");
            return 120;
        }
        /* THE GUARD'S PATTERN COMES OUT OF THE COMMAND, NOT OUT OF THIS FILE, and getting that
         * wrong once is why the comment is this long. The first version hardcoded "wsl" here, so
         * the guard being asserted was THIS PROGRAM'S and not the .cmd's: rewriting the .cmd's
         * `-match 'wsl'` to `-match ''` -- which is true for every string, and would delete a
         * student's retargeted shortcut -- left the tier at 235 pass 0 fail. Same class of
         * defect as #270 itself, one layer down, and the same lesson lib/sandbox.sh records for
         * the fake that "agreed with the installer's reasoning and so could not contradict it".
         *
         * NO -match AT ALL MEANS NO GUARD, deliberately, rather than a harness failure: deleting
         * the guard outright is the obvious mutation, and it has to be able to go red. An empty
         * pattern falls out of the same rule -- fake_contains_ci("") is true -- so both ways of
         * weakening it behave the way PowerShell would.
         *
         * A SUBSTRING WHERE POWERSHELL WOULD RUN A REGEX, which is the one approximation here.
         * It is exact for every pattern this .cmd can hold today and for the mutations above;
         * a case that needed anchors or a character class would need this to grow, and a fake
         * that quietly matched something a regex would not is worth noticing at that point. */
        char guard[256] = "";
        int guarded = quoted_after(argc, argv, "-match '", guard, sizeof guard);
        for (i = 0; i < n; i++) {
            char target[1024];
            if (!fake_lnk_target(lits[i], target, sizeof target)) continue;  /* Test-Path: no */
            if (guarded && !fake_contains_ci(target, guard)) continue;       /* the guard: no */
            remove(lits[i]);
        }
        return answer("ps.del.rc", 0);
    }

    /* THE ENTRY THE INSTALLER CREATES. .Save() is the marker the delete does not carry, but the
     * arm above has already claimed that one, so what this really depends on is the ordering. */
    if (mentions(argc, argv, "CreateShortcut")) {
        char lits[PS_MAX_LNK][512];
        char target[1024] = "", args[1024] = "", icon[1024] = "";
        if (lnk_literals(argc, argv, lits) == 0) {
            fprintf(stderr, "win-fake: the shortcut named no .lnk path\n");
            return 120;
        }
        quoted_after(argc, argv, "$s.TargetPath = '",   target, sizeof target);
        quoted_after(argc, argv, "$s.Arguments = '",    args,   sizeof args);
        quoted_after(argc, argv, "$s.IconLocation = '", icon,   sizeof icon);
        if (!fake_lnk_write(lits[0], target, args, icon)) {
            fprintf(stderr, "win-fake: could not write %s\n", lits[0]);
            return 1;
        }
        return answer("ps.lnk.rc", 0);
    }

    fprintf(stderr, "win-fake: powershell asked an unrecognised question: %s\n",
            argc > 1 ? argv[argc-1] : "(no arguments)");
    return 120;
}

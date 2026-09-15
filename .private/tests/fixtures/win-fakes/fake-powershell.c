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
static int answer(const char *rcknob, int value) {
    long forced = fake_knob_int("ps.rc", -1);
    if (forced >= 0) return (int)forced;
    forced = fake_knob_int(rcknob, -1);
    if (forced >= 0) return (int)forced;
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

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);

    const char *distro = getenv("CS193V_FAKE_DISTRO");
    if (!distro) distro = "CS193V";

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

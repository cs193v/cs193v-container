/* powershell.exe, for the -Command probes the installer runs. FOUR of them now, not one.
 *
 * WHY IT DISPATCHES ON THE COMMAND TEXT. This fake used to answer the only question the
 * installer asked -- does the CS193V distro exist -- so it needed no idea which question it was
 * being asked. Issue #112 added three more, and a fake that answered them all from one knob
 * would let a case arrange a self-contradictory machine: a hypervisor that is absent and a
 * distro that exists because the same `ps.rc` said 0 to both. So the marker is read off the
 * -Command text, which is the .cmd's OWN string -- an installer that stops asking one of these
 * stops matching here, rather than silently getting the previous answer.
 *
 * AN UNRECOGNISED PROBE IS A HARNESS FAILURE, not a "no". exit 120 is the same code fake_say
 * uses for a missing message key, and for the same reason: a fake that guessed 1 would report
 * every new probe as a negative answer, and the case asserting on that negative would pass.
 *
 * THE DISTRO PROBE STILL EVALUATES rather than answering from a knob. It reads the same
 * wsl.list state fake-wsl.c writes to, so the real sequence -- probe, create, probe again --
 * behaves the way it would on a machine.
 *
 * Exit codes follow the real -Command contract: the answer arrives AS a code, 0 or 1. Anything
 * else means the probe itself could not run (powershell absent gives cmd's 9009), which is a
 * different thing from "absent" -- the installer has a separate arm for each, so the fake needs
 * a way to produce it. `ps.rc` forces EVERY probe, which is what "powershell is missing" looks
 * like; the per-probe `ps.*.rc` knobs force one at a time.
 */
#include "win-fake.h"

/* Does any argument contain this text? The markers below are substrings of the .cmd's own
 * PowerShell, so this is deliberately not an exact match on the whole command line. */
static int mentions(int argc, char **argv, const char *needle) {
    for (int i = 1; i < argc; i++) if (strstr(argv[i], needle)) return 1;
    return 0;
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

/* The distro probe, evaluated against the list fake-wsl.c maintains. */
static int distro_present(void) {
    const char *distro = getenv("CS193V_FAKE_DISTRO");
    if (!distro) distro = "CS193V";

    char p[1024], line[512];
    fake_path(p, sizeof p, "wsl.list");
    FILE *f = fopen(p, "rb");
    if (!f) return 0;                       /* nothing registered -> absent */
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
        /* the real probe anchors with -match '^CS193V$', so CS193V-old must not match */
        if (n && strcmp(line, distro) == 0) { found = 1; break; }
    }
    fclose(f);
    return found;
}

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);

    /* Is a hypervisor actually loaded? The OUTCOME question, and false for every cause of
     * HCS_E_HYPERV_NOT_INSTALLED -- firmware off, a guest VM without nested virtualisation, or
     * hypervisorlaunchtype Off. */
    if (mentions(argc, argv, "HypervisorPresent"))
        return answer("ps.virt.rc", fake_knob_int("ps.novirt", 0) ? 1 : 0);

    /* Is the Virtual Machine Platform optional component on? This is the one the installer can
     * fix, so it is the question that splits "enable it and restart" from "refuse". */
    if (mentions(argc, argv, "VirtualMachinePlatform"))
        return answer("ps.vmp.rc", fake_knob_int("ps.vmp.disabled", 0) ? 1 : 0);

    /* Is the hypervisor switched off in the boot configuration? 1 means Off, i.e. the problem is
     * present -- the same polarity as the other two, where 0 is "nothing wrong here". */
    if (mentions(argc, argv, "hypervisorlaunchtype"))
        return answer("ps.launchtype.rc", fake_knob_int("ps.launchtype.off", 0) ? 1 : 0);

    /* Does the CS193V distro exist? WSL_UTF8 is the marker because batch cannot read wsl.exe's
     * UTF-16, which is the whole reason this probe goes through PowerShell at all. */
    if (mentions(argc, argv, "WSL_UTF8"))
        return answer("ps.distro.rc", distro_present() ? 0 : 1);

    fprintf(stderr, "win-fake: powershell asked an unrecognised question: %s\n",
            argc > 1 ? argv[argc-1] : "(no arguments)");
    return 120;
}

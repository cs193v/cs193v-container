/* powershell.exe, for the -Command probes the installer runs. TWO of them, not four.
 *
 * WHY IT DISPATCHES ON THE COMMAND TEXT. This fake once answered the only question the installer
 * asked -- does the CS193V distro exist -- so it needed no idea which question it was being asked.
 * Issue #112 added three more, and a fake that answered them all from one knob would let a case
 * arrange a self-contradictory machine. So the marker is read off the -Command text, which is the
 * .cmd's OWN string -- an installer that stops asking one of these stops matching here, rather
 * than silently getting the previous answer.
 *
 * THREE OF THOSE FOUR ARE GONE, and issue #114 is why. They asked WHICH cause stopped a VM from
 * starting -- HypervisorPresent, then VirtualMachinePlatform, then hypervisorlaunchtype -- and
 * the first was WRONG on a VirtualBox guest, where a hypervisor is present but not one WSL2 can
 * build a VM with. The installer no longer asks about the machine at all: it makes WSL start a VM
 * and looks. So the probes here are both the same shape now, `wsl -l -q` against a name.
 *
 * THE COMMENT THAT USED TO BE HERE claimed HypervisorPresent was "false for every cause" of
 * HCS_E_HYPERV_NOT_INSTALLED. It was not, and this fake asserting it in prose is part of why no
 * test caught the defect: the fixture agreed with the installer's mistake.
 *
 * AN UNRECOGNISED PROBE IS A HARNESS FAILURE, not a "no". exit 120 is the same code fake_say uses
 * for a missing message key, and for the same reason: a fake that guessed 1 would report every new
 * probe as a negative answer, and the case asserting on that negative would pass.
 *
 * BOTH PROBES STILL EVALUATE rather than answering from a knob. They read the same wsl.list state
 * fake-wsl.c writes to, so the real sequences -- probe, create, probe again; import, probe,
 * unregister -- behave the way they would on a machine.
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

/* Is NAME in the list fake-wsl.c maintains? Both probes are this question about different names,
 * which is the point: the gate's answer is "did the throwaway environment register", in exactly
 * the terms the distro probe already used. */
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
    const char *vmcheck = getenv("CS193V_FAKE_VMCHECK");
    if (!vmcheck) vmcheck = "CS193V-vmcheck";

    /* THE GATE, and it must be tested BEFORE the distro probe: both commands set WSL_UTF8 and
     * both run `wsl -l -q`, so the only thing telling them apart is the name each anchors on.
     * Matching on the distro marker first would answer the gate with the student's environment,
     * which is the one confusion that would make the whole gate meaningless. */
    if (mentions(argc, argv, vmcheck))
        return answer("ps.vmcheck.rc", listed(vmcheck) ? 0 : 1);

    /* Does the CS193V distro exist? WSL_UTF8 is the marker because batch cannot read wsl.exe's
     * UTF-16, which is the whole reason this probe goes through PowerShell at all. */
    if (mentions(argc, argv, "WSL_UTF8"))
        return answer("ps.distro.rc", listed(distro) ? 0 : 1);

    fprintf(stderr, "win-fake: powershell asked an unrecognised question: %s\n",
            argc > 1 ? argv[argc-1] : "(no arguments)");
    return 120;
}

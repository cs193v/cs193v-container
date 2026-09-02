/* powershell.exe, for the -Command probes the installer runs. TWO of them, not four.
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

    fprintf(stderr, "win-fake: powershell asked an unrecognised question: %s\n",
            argc > 1 ? argv[argc-1] : "(no arguments)");
    return 120;
}

/* net.exe, for the `net session` admin probe only.
 *
 * Three exit codes, and the middle one is the reason the idiom is unsafe: 0 elevated,
 * 5 not elevated, and 2 when the Server (LanmanServer) service is stopped -- so a real
 * Administrator on a hardened machine is reported as not one. Tier C: net.exe is a closed
 * component, so the wording is third-party-attested and the suite gates on the codes.
 *
 * Wine ships its own net.exe which answers `session` with a usage banner and exit 0 -- i.e. it
 * reports EVERY user as elevated. Measured. That is why this fake exists at all, and why
 * Containerfile.wine installs it OVER wine's copy in the prefix's own system32. It used to say
 * the shim directory had to precede system32 on the Windows PATH; nothing ever arranged that, and
 * what actually did the shadowing was cmd.exe searching the current directory first -- the defect
 * issue #125 reports. The installer no longer resolves anything that way.
 *
 * THE PROBE ITSELF IS RETIRED: the .cmd uses `reg query "HKU\S-1-5-19"` because `net session`
 * exits 2 when the Server service is stopped, which hardening baselines routinely do. This fake is
 * kept so the codes stay documented and a return to the idiom has something to run against.
 */
#include "win-fake.h"

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);
    if (argc > 1 && (strcmp(argv[1], "session") == 0 || strcmp(argv[1], "SESSION") == 0)) {
        long rc = fake_knob_int("net.session.rc", 0);
        if (rc == 5)      fake_say(stdout, "NetSessionNotElevated", NULL, NULL);
        else if (rc == 2) fake_say(stdout, "NetSessionNoServer", NULL, NULL);
        else              fake_say(stdout, "NetSessionElevated", NULL, NULL);
        return (int)rc;
    }
    return 0;
}

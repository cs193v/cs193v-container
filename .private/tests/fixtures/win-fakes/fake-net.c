/* net.exe, for the `net session` admin probe only.
 *
 * Three exit codes, and the middle one is the reason the idiom is unsafe: 0 elevated,
 * 5 not elevated, and 2 when the Server (LanmanServer) service is stopped -- so a real
 * Administrator on a hardened machine is reported as not one. Tier C: net.exe is a closed
 * component, so the wording is third-party-attested and the suite gates on the codes.
 *
 * Wine ships its own net.exe which answers `session` with a usage banner and exit 0 -- i.e. it
 * reports EVERY user as elevated. Measured. That is why the shim directory must precede
 * system32 on the Windows PATH, and why this fake exists at all.
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

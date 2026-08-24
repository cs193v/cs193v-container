/* powershell.exe, for the one -Command the installer runs: does the CS193V distro exist?
 *
 * This fake does not take "yes" or "no" from a knob. It EVALUATES the question against the same
 * wsl.list state fake-wsl.c writes to, so the real sequence -- probe, create, probe again --
 * behaves the way it would on a machine, and a case cannot accidentally assert a
 * self-contradictory world where the install succeeded but the distro is still absent.
 *
 * Exit codes follow the real -Command contract: the answer arrives AS a code, 0 or 1. Anything
 * else means the probe itself could not run (powershell absent gives cmd's 9009), which is a
 * different thing from "absent" -- the installer has a separate arm for it, so the fake needs a
 * way to produce it. ps.rc is that way.
 */
#include "win-fake.h"

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);

    /* -1 is not a plausible answer to a yes/no question, so it doubles as "unset". */
    long forced = fake_knob_int("ps.rc", -1);
    if (forced >= 0) return (int)forced;

    const char *distro = getenv("CS193V_FAKE_DISTRO");
    if (!distro) distro = "CS193V";

    char p[1024], line[512];
    fake_path(p, sizeof p, "wsl.list");
    FILE *f = fopen(p, "rb");
    if (!f) return 1;                       /* nothing registered -> absent */
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
        /* the real probe anchors with -match '^CS193V$', so CS193V-old must not match */
        if (n && strcmp(line, distro) == 0) { found = 1; break; }
    }
    fclose(f);
    return found ? 0 : 1;
}

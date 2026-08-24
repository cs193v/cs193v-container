/* wsl.exe. Nine invocation shapes, and the behaviours that make the real one hard to use:
 *
 *   - generic failure is -1 (0xFFFFFFFF), NOT 1. `if errorlevel 1` is a >= test and so cannot
 *     see it. This is the single most important thing this fake reproduces.
 *   - errors go to STDOUT, so an unguarded `for /f` capture takes an error message as a value.
 *   - `--status` exits 0 even with zero distributions registered.
 *   - `-l -q` exits 0 with EMPTY output when there are none.
 *   - default output is UTF-16LE with no BOM unless WSL_UTF8=1.
 *   - `--install` LAUNCHES the distro and returns the launched shell's code, not the install's.
 *
 * Source for all of the above: microsoft/WSL @ 2.9.8, src/windows/common/WslClient.cpp.
 */
#include "win-fake.h"

#define WSL_FAIL (-1)

static int has(int argc, char **argv, const char *needle) {
    for (int i = 1; i < argc; i++) if (strcmp(argv[i], needle) == 0) return 1;
    return 0;
}

/* Print the message named by a knob, if that knob is set, then return the knob'd exit code.
 * `msgknob` holds a MESSAGE KEY, never prose, so every string stays in the fixture table. */
static int answer(const char *rcknob, const char *msgknob, long dfltrc, const char *a) {
    char key[128];
    long rc = fake_knob_int(rcknob, dfltrc);
    if (fake_knob(msgknob, key, sizeof key) && key[0]) {
        /* wsl.exe wraps thrown errors in MessageErrorCode; a plain message is printed bare. */
        char code[128];
        if (fake_knob("wsl.errorcode", code, sizeof code) && code[0]) {
            char body[4096];
            if (!fake_msg(key, body, sizeof body)) {
                fprintf(stderr, "win-fake: no message keyed '%s'\n", key);
                return 120;
            }
            fake_fmt(body, sizeof body, a, NULL);
            fake_say(stdout, "MessageErrorCode", body, code);
        } else {
            fake_say(stdout, key, a, "wsl.exe");
        }
    }
    return (int)rc;
}

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);
    const char *distro = getenv("CS193V_FAKE_DISTRO");
    if (!distro) distro = "CS193V";

    if (has(argc, argv, "--status"))
        return answer("wsl.status.rc", "wsl.status.msg", 0, NULL);

    if (has(argc, argv, "--update"))
        return answer("wsl.update.rc", "wsl.update.msg", 0, NULL);

    if (has(argc, argv, "--install") && has(argc, argv, "--no-distribution"))
        return answer("wsl.feature.rc", "wsl.feature.msg", 0, NULL);

    /* `--install -d X --name Y`. The real one downloads, registers, prints two lines, then
     * LAUNCHES -- so the code it returns belongs to the launched shell. wsl.install.rc is
     * therefore deliberately named for the shell, not the install. */
    if (has(argc, argv, "--install")) {
        char list[1024];
        if (has(argc, argv, "--name") && fake_knob_int("wsl.name.unsupported", 0)) {
            /* WSL < 2.5.8 has no --name at all: unknown argument, printed bare, exit -1. */
            fake_say(stdout, "MessageInvalidCommandLine", "--name", "wsl.exe");
            return WSL_FAIL;
        }
        if (!fake_knob_int("wsl.install.fails", 0)) {
            fake_say(stdout, "MessageDistributionInstalled", distro, NULL);
            fake_say(stdout, "MessageLaunchingDistro", distro, NULL);
            /* registered now: later probes must see it */
            char p[1024]; FILE *f;
            fake_path(p, sizeof p, "wsl.list");
            if ((f = fopen(p, "a"))) { fprintf(f, "%s\n", distro); fclose(f); }
            (void)list;
        } else {
            fake_say(stdout, "MessageDistroNameAlreadyExists", NULL, NULL);
            return WSL_FAIL;
        }
        return (int)fake_knob_int("wsl.install.rc", 0);
    }

    if (has(argc, argv, "-l") || has(argc, argv, "--list")) {
        char p[1024], line[512];
        FILE *f;
        int quiet = has(argc, argv, "-q") || has(argc, argv, "--quiet");
        fake_path(p, sizeof p, "wsl.list");
        f = fopen(p, "rb");
        int any = 0;
        if (f) {
            while (fgets(line, sizeof line, f)) {
                size_t n = strlen(line);
                while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
                if (!n) continue;
                if (!any && !quiet) fake_say(stdout, "MessageRegisteredDistrosHeader", NULL, NULL);
                any = 1;
                fake_write_line(line);
            }
            fclose(f);
        }
        /* -q with nothing registered: exit 0 and print NOTHING. Without -q the real one throws
         * WSL_E_DEFAULT_DISTRO_NOT_FOUND and prints the four-line block with no Error code:. */
        if (!any && !quiet) { fake_say(stdout, "MessageNoDefaultDistro", NULL, NULL); return WSL_FAIL; }
        return 0;
    }

    if (has(argc, argv, "wslpath")) {
        char out[1024];
        long rc = fake_knob_int("wsl.wslpath.rc", 0);
        if (rc != 0) {
            /* The error lands on STDOUT, which is what makes an unvalidated capture dangerous. */
            fake_say(stdout, "MessageDistroNotFound", NULL, NULL);
            fake_say(stdout, "MessageErrorCode", "", "Wsl/Service/WSL_E_DISTRO_NOT_FOUND");
            return (int)rc;
        }
        if (!fake_knob("wsl.wslpath.out", out, sizeof out))
            snprintf(out, sizeof out, "/mnt/c/Users/student/Downloads/install-cs193v.sh");
        if (out[0]) printf("%s\n", out);
        return 0;
    }

    if (has(argc, argv, "bash"))
        return (int)fake_knob_int("wsl.bash.rc", 0);

    fake_say(stdout, "MessageInvalidCommandLine", argc > 1 ? argv[1] : "", "wsl.exe");
    return WSL_FAIL;
}

/* wsl.exe. Ten invocation shapes, and the behaviours that make the real one hard to use:
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
 *
 * FOUR OF THE SHAPES ARE `-e` PROGRAMS RUN INSIDE THE DISTRO, not wsl.exe subcommands: the
 * curl probe, apt-get, curl downloading, and grep. They are here rather than in fakes of their
 * own because that is genuinely how the .cmd invokes them -- `wsl.exe -d X -e curl ...` -- so
 * the argv this program sees is the argv the real wsl.exe would see, and the windows tier runs
 * with --network=none, where a real curl could not work anyway.
 *
 * AND THEY EXCHANGE FILES RATHER THAN ANSWER KNOBS, the way the --install arm already appends
 * to wsl.list so a later probe sees it. apt-get writes `curl.installed`, which is what makes
 * the .cmd's probe/install/re-probe sequence real: a .cmd that installed curl and then failed
 * to re-check would pass a knob-based fake and fails this one. curl copies `stage2.src` -- THE
 * ACTUAL install-cs193v.sh, put there by wine_new -- to `stage2.sh`, whole or cut short, and
 * grep searches that file for the pattern the .cmd passed. So the sentinel check is exercised
 * against the real script's real last line; nothing here knows what the token is.
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

static int exists(const char *leaf) {
    char p[1024]; FILE *f;
    fake_path(p, sizeof p, leaf);
    if (!(f = fopen(p, "rb"))) return 0;
    fclose(f);
    return 1;
}

/* Copy stage2.src to stage2.sh. `cut` > 0 stops after that many bytes, which is how both a
 * short read and a captive portal's substituted page are modelled: the observable the .cmd
 * checks is the same one -- the sentinel on the last line is not there. */
static int serve_stage2(long cut) {
    char src[1024], dst[1024], buf[4096];
    FILE *in, *out;
    size_t n;
    long written = 0;
    fake_path(src, sizeof src, "stage2.src");
    fake_path(dst, sizeof dst, "stage2.sh");
    if (!(in = fopen(src, "rb"))) return -1;
    if (!(out = fopen(dst, "wb"))) { fclose(in); return -1; }
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        if (cut > 0 && written + (long)n > cut) n = (size_t)(cut - written);
        if (n == 0) break;
        fwrite(buf, 1, n, out);
        written += (long)n;
        if (cut > 0 && written >= cut) break;
    }
    fclose(in);
    fclose(out);
    return 0;
}

/* Whole file into memory and strstr, because the token the .cmd looks for is on the LAST line:
 * a streaming search with a small window is exactly the thing that would find it by accident or
 * miss it at a chunk boundary. 1 MB against a 40 KB script leaves room to grow; if it ever
 * overflowed, the sentinel would fall off the end and every check here would go red rather
 * than quietly pass, which is the right direction to fail in. */
static int stage2_contains(const char *needle) {
    static char body[1 << 20];
    char p[1024];
    FILE *f;
    size_t n;
    fake_path(p, sizeof p, "stage2.sh");
    if (!(f = fopen(p, "rb"))) return 0;
    n = fread(body, 1, sizeof body - 1, f);
    fclose(f);
    body[n] = '\0';
    return strstr(body, needle) != NULL;
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
            /* `--install` LAUNCHES the distro, and what a student then sees is Canonical's
             * first-run setup -- three questions on 26.04, not two. Replayed rather than
             * skipped because the installer's own on-screen text promises exactly this, and a
             * promise about output that never appears cannot be checked. Non-interactive: the
             * prompts are shown with the answers already filled in, which is why wincmd says so
             * afterwards rather than leaving you to think the harness took your input. */
            if (fake_knob_int("wsl.oobe", 1)) {
                char user[128];
                if (!fake_knob("wsl.oobe.user", user, sizeof user) || !user[0])
                    snprintf(user, sizeof user, "student");
                fake_say(stdout, "OobeProvisioning", distro, NULL);
                fake_say(stdout, "OobeWait", NULL, NULL);
                fake_say(stdout, "OobeCreateUser", user, NULL);
                fake_say(stdout, "OobeNewPassword", NULL, NULL);
                fake_say(stdout, "OobeRetypePassword", NULL, NULL);
                fake_say(stdout, "OobePasswdOk", NULL, NULL);
                /* 26.04 only. Gated so the 24.04 shape can be driven too, because the
                 * difference is exactly one question and the installer's text counts them. */
                if (fake_knob_int("wsl.oobe.insights", 1)) {
                    fake_say(stdout, "OobeInsightsTitle", NULL, NULL);
                    fake_say(stdout, "OobeInsightsBody", NULL, NULL);
                    fake_say(stdout, "OobeInsightsPrompt", NULL, NULL);
                    fake_say(stdout, "OobeInsightsChoice", NULL, NULL);
                }
            }
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

    /* `-e curl --version`: is curl in the distro at all? Checked BEFORE the download, so a
     * missing program is not reported as a network problem. The marker is what makes the
     * .cmd's re-probe after apt-get mean something. */
    if (has(argc, argv, "curl") && has(argc, argv, "--version")) {
        if (fake_knob_int("wsl.curl.missing", 0) && !exists("curl.installed")) return WSL_FAIL;
        return 0;
    }

    /* `-u root -e apt-get ...`, which is how stage one fixes a missing curl rather than
     * refusing over it. wsl.apt.nomarker models the nastiest shape: apt exits 0 and curl is
     * still not there, which only the re-probe can catch. */
    if (has(argc, argv, "apt-get")) {
        if (has(argc, argv, "update"))
            return (int)fake_knob_int("wsl.apt.update.rc", 0);
        if (has(argc, argv, "install")) {
            long rc = fake_knob_int("wsl.apt.install.rc", 0);
            if (rc == 0 && !fake_knob_int("wsl.apt.nomarker", 0)) {
                char p[1024]; FILE *f;
                fake_path(p, sizeof p, "curl.installed");
                if ((f = fopen(p, "w"))) { fputc('1', f); fclose(f); }
            }
            return (int)rc;
        }
        return WSL_FAIL;
    }

    /* `-e curl -fsSL ... -o <path> <url>`: the download. On success it really writes the file
     * the grep arm below then reads, so the two are not independently stubbed. */
    if (has(argc, argv, "curl")) {
        long rc = fake_knob_int("wsl.curl.rc", 0);
        if (rc != 0) return (int)rc;
        if (serve_stage2(fake_knob_int("wsl.curl.truncated", 0) ? 2000 : 0) != 0) return WSL_FAIL;
        return 0;
    }

    /* `-e grep -q PATTERN FILE`. The pattern is the first argv entry after `grep` that does not
     * start with `-`; the FILE argument is deliberately ignored, since the only thing this fake
     * can serve is what its own curl arm wrote. The pattern, though, is the .cmd's own -- so a
     * .cmd looking for the wrong token fails here. */
    if (has(argc, argv, "grep")) {
        const char *pat = NULL;
        int i, seen = 0;
        for (i = 1; i < argc; i++) {
            if (strcmp(argv[i], "grep") == 0) { seen = 1; continue; }
            if (!seen || argv[i][0] == '-') continue;
            pat = argv[i];
            break;
        }
        if (!pat) return WSL_FAIL;
        return stage2_contains(pat) ? 0 : 1;
    }

    if (has(argc, argv, "bash")) {
        /* A VISIBLE boundary, not install-cs193v.sh's transcript. That script is this repo's own
         * and has its own coverage; reproducing its output here would be inventing prose and
         * duplicating tests. Printing nothing was worse: the handoff looked like it had not
         * happened at all. */
        if (fake_knob_int("wsl.stage2.quiet", 0) == 0)
            fake_say(stdout, "Stage2Boundary", NULL, NULL);
        return (int)fake_knob_int("wsl.bash.rc", 0);
    }

    fake_say(stdout, "MessageInvalidCommandLine", argc > 1 ? argv[1] : "", "wsl.exe");
    return WSL_FAIL;
}

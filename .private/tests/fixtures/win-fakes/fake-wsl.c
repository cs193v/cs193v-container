/* wsl.exe. Every invocation shape the .cmd uses, and the behaviours that make the real one hard
 * to use:
 *
 *   - generic failure is -1 (0xFFFFFFFF), NOT 1. `if errorlevel 1` is a >= test and so cannot
 *     see it. This is the single most important thing this fake reproduces.
 *   - errors go to STDOUT, so an unguarded `for /f` capture takes an error message as a value.
 *   - `--status` exits 0 even with zero distributions registered. It also exits 0 while PRINTING
 *     that the Virtual Machine Platform is missing -- Status() ends in an unconditional
 *     `return 0` -- which is issue #112: the .cmd read the code and discarded the message.
 *   - `-l -q` exits 0 with EMPTY output when there are none.
 *   - default output is UTF-16LE with no BOM unless WSL_UTF8=1.
 *   - `--install` LAUNCHES the distro and returns the launched shell's code, not the install's.
 *   - `--install -d` can enable a Windows component, print a reboot notice, install NOTHING and
 *     exit ZERO -- so "it exited 0" and "the distro is there" are unrelated claims.
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

/* The value of `-d`, which is an IMAGE name under --install and a REGISTERED DISTRO name
 * everywhere else. Returns NULL when the flag is absent. */
static const char *dashd(int argc, char **argv) {
    for (int i = 1; i + 1 < argc; i++)
        if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--distribution") == 0)
            return argv[i+1];
    return NULL;
}

static int registered(const char *name) {
    char p[1024], line[512];
    FILE *f;
    if (!name) return 0;
    fake_path(p, sizeof p, "wsl.list");
    if (!(f = fopen(p, "rb"))) return 0;
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
        if (n && strcmp(line, name) == 0) { fclose(f); return 1; }
    }
    fclose(f);
    return 0;
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


/* ─── the markers the root pass exchanges (#217) ───────────────────────────────
 * WHY MARKERS AND NOT KNOBS. A knob answers the same way however many times it is asked, which
 * is fine for "this machine has no virtualisation" and useless for a sequence: the .cmd's whole
 * provisioning flow is an ORDER -- switch the first-run setup off, create the account, restart
 * the instance, check who owns the home directory, and only then run the student's half. So each
 * step writes a file and the steps after it read one, exactly as the --install arm already
 * appends to wsl.list and apt-get already writes curl.installed. A .cmd that got the order wrong
 * then fails here rather than passing a fake that cannot tell.
 */
static void touch_marker(const char *leaf) {
    char p[1024]; FILE *f;
    fake_path(p, sizeof p, leaf);
    if ((f = fopen(p, "w"))) { fputc('1', f); fclose(f); }
}

static void write_marker(const char *leaf, const char *body) {
    char p[1024]; FILE *f;
    fake_path(p, sizeof p, leaf);
    if ((f = fopen(p, "w"))) { fputs(body, f); fclose(f); }
}

static void remove_marker(const char *leaf) {
    char p[1024];
    fake_path(p, sizeof p, leaf);
    remove(p);
}

/* Where the .cmd told curl to write stage 2, recorded by the curl arm. Read by --terminate,
 * because a /tmp inside a systemd WSL instance is a tmpfs and does not survive a restart. */
static int stage2_is_in_tmp(void) {
    char p[1024], dest[1024];
    FILE *f;
    size_t n;
    fake_path(p, sizeof p, "stage2.dest");
    if (!(f = fopen(p, "rb"))) return 0;
    n = fread(dest, 1, sizeof dest - 1, f);
    fclose(f);
    dest[n] = '\0';
    while (n && (dest[n-1] == '\n' || dest[n-1] == '\r')) dest[--n] = '\0';
    return strncmp(dest, "/tmp/", 5) == 0;
}
int main(int argc, char **argv) {
    fake_log_argv(argc, argv);
    const char *distro = getenv("CS193V_FAKE_DISTRO");
    if (!distro) distro = "CS193V";

    /* `--status`, MODELLED LINE FOR LINE off Status() (WslClient.cpp:1179-1209), because the
     * shape of that function IS issue #112: it prints the default distro, the default version,
     * then a line if the WSL optional component is missing and a line if vmcompute is missing --
     * and then `return 0` UNCONDITIONALLY. So a machine with no Virtual Machine Platform says so
     * on STDOUT and still exits zero. A fake that answered only from a knob could not express
     * that, which is why no case ever did.
     *
     * wsl.status.msg is kept alongside: it is the INBOX STUB's shape, where wsl.exe is a
     * placeholder that prints one thing and exits non-zero, and that is a different machine. */
    if (has(argc, argv, "--status")) {
        /* The DEFAULT distribution, which is the first registered one here. Real WSL picks it by
         * a flag; the .cmd never reads this line, so modelling the flag would be detail for its
         * own sake. What matters is that --status prints something and still exits 0. */
        char list[1024], line[512];
        FILE *lf;
        fake_path(list, sizeof list, "wsl.list");
        if ((lf = fopen(list, "rb"))) {
            while (fgets(line, sizeof line, lf)) {
                size_t n = strlen(line);
                while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
                if (n) { fake_say(stdout, "MessageStatusDefaultDistro", line, NULL); break; }
            }
            fclose(lf);
        }
        fake_say(stdout, "MessageStatusDefaultVersion", "2", NULL);
        if (fake_knob_int("wsl.status.nowsl1", 0))
            fake_say(stdout, "MessageWsl1NotSupported", NULL, NULL);
        /* THE LINE THE .cmd USED TO SEND TO nul. */
        if (fake_knob_int("wsl.status.novirt", 0))
            fake_say(stdout, "MessageEnableVirtualization", NULL, NULL);
        return answer("wsl.status.rc", "wsl.status.msg", 0, NULL);
    }

    if (has(argc, argv, "--update"))
        return answer("wsl.update.rc", "wsl.update.msg", 0, NULL);

    /* `--install --no-distribution`: enable the Windows components and nothing else. It closes
     * with PrintSystemError -- ERROR_SUCCESS_REBOOT_REQUIRED when it enabled something (which is
     * the only reason the .cmd ever calls it), NO_ERROR when there was nothing to do. */
    if (has(argc, argv, "--install") && has(argc, argv, "--no-distribution")) {
        int rc = answer("wsl.feature.rc", "wsl.feature.msg", 0, NULL);
        if (rc == 0)
            fake_say(stdout, fake_knob_int("wsl.feature.nothingmissing", 0)
                             ? "SystemErrorSuccess" : "SystemErrorRebootRequired", NULL, NULL);
        return rc;
    }

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
        /* THE SAME SHAPE FOR --no-launch, AND IT IS WHAT MAKES THE .cmd's EXIT CHECK REACHABLE
         * (#217). --no-launch is far older than --name -- it predates the 2.4.4 floor the
         * installer's docs now name -- so no supported WSL rejects it. But the .cmd tests
         * --install's exit code for the first time, and an assertion whose failure arm cannot
         * be produced is an assertion in appearance only, so the knob exists to produce it. */
        if (has(argc, argv, "--no-launch") && fake_knob_int("wsl.nolaunch.unsupported", 0)) {
            fake_say(stdout, "MessageInvalidCommandLine", "--no-launch", "wsl.exe");
            return WSL_FAIL;
        }
        /* THE PREREQUISITE ARM, AND IT RUNS BEFORE ANY DOWNLOAD. Install() calls
         * InstallPrerequisites FIRST (WslClient.cpp:544), and when a component had to be enabled
         * it sets rebootRequired -- which makes the `legacy || !rebootRequired` guard on
         * InstallDistribution FALSE. So wsl.exe enables the feature, prints the reboot notice,
         * installs NOTHING, and exits ZERO. That combination is the shape no knob here could
         * express before, and it is the one that tells a student with a clean Windows 11 box
         * that they need a newer WSL when all they needed was a restart (issue #112).
         *
         * MessageInstallingWindowsComponent is what the real one also prints here, and it is
         * NOT in the fixture table -- absent rather than guessed, per that file's own rule -- so
         * it is not replayed. The observables the .cmd consumes are the exit code and the fact
         * that nothing got registered, and both are faithful. */
        if (fake_knob_int("wsl.install.rebootrequired", 0)) {
            fake_say(stdout, "SystemErrorRebootRequired", NULL, NULL);
            return 0;
        }
        /* THE #112 SHAPE. Prerequisites pass -- the component is on, the services exist -- so
         * the download really happens, and it is CreateVm that throws, at which point the .wsl
         * has already been fetched. That ordering is the whole reason a pre-flight is worth
         * having: without one the refusal arrives after 600 MB.
         *
         * The name printed is the `-d` argument rather than the manifest's friendly name
         * ("Ubuntu 26.04 LTS" in the issue transcript). The friendly name belongs to Microsoft's
         * distribution manifest, moves without notice, and nothing may assert on it. */
        if (fake_knob_int("wsl.install.novirt", 0)) {
            const char *image = dashd(argc, argv);
            fake_say(stdout, "MessageDownloading", image ? image : distro, NULL);
            fake_say(stdout, "MessageInstalling", image ? image : distro, NULL);
            /* Wrapped in MessageErrorCode, which is the envelope EVERY thrown error gets --
             * `{}\nError code: {}`. Both halves come from the table: the prose, and the scope
             * chain ExecutionContext assembles at run time. Nothing here invents either. */
            char body[4096], code[512];
            if (!fake_msg("MessageEnableVirtualization", body, sizeof body)
                || !fake_msg("ErrorCodeCreateVmNoHyperv", code, sizeof code)) {
                fprintf(stderr, "win-fake: the virtualisation failure needs both "
                                "MessageEnableVirtualization and ErrorCodeCreateVmNoHyperv\n");
                return 120;
            }
            fake_say(stdout, "MessageErrorCode", body, code);
            return WSL_FAIL;
        }
        if (!fake_knob_int("wsl.install.fails", 0)) {
            /* The two lines that precede every real install, and the reason the novirt arm above
             * is worth having: they are what tells you the download had already happened. */
            const char *image = dashd(argc, argv);
            fake_say(stdout, "MessageDownloading", image ? image : distro, NULL);
            fake_say(stdout, "MessageInstalling", image ? image : distro, NULL);
            fake_say(stdout, "MessageDistributionInstalled", distro, NULL);
            /* NO LAUNCH, AND NO FIRST-RUN SETUP TO REPLAY (#217). The .cmd passes --no-launch,
             * so the distribution is registered and nothing runs inside it: no Canonical
             * account questions, no telemetry question, nothing for a student to type. Ten
             * Oobe* keys were retired from the fixture table with the replay that printed them.
             *
             * WHICH ALSO CHANGES WHAT THE EXIT CODE MEANS. Without --no-launch the code
             * belonged to the LAUNCHED SHELL, so a student who mistyped before `exit` looked
             * like a failed install and the .cmd could not test it. With --no-launch it is the
             * install's own, which is why the .cmd now tests it and why wsl.install.rc is
             * documented as the install's code. */
            if (!has(argc, argv, "--no-launch"))
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

    /* `--terminate NAME`. Two things make this worth a real arm rather than a knob.
     *
     * IT IS WHAT MAKES /etc/wsl.conf TAKE EFFECT, and the .cmd cannot skip it: wsl.conf is read
     * when the instance STARTS, and an idle instance lingers for InstanceIdleTimeout (15 s), so
     * consecutive `wsl.exe` calls from a batch file reuse the instance AND the configuration it
     * booted with. Without the terminate, the pass that runs as the student would run as root.
     * The `test -O` arm below is 0 only once this has been seen, so the ordering is asserted
     * rather than assumed.
     *
     * AND IT WIPES /tmp, WHICH CHANGED THE DESIGN. Measured in a real CS193V instance on
     * 2026-09-10: with systemd=true, /tmp is a tmpfs, so a file downloaded there does not
     * survive the restart. Stage 2 therefore lives in /var/tmp, which does -- and this arm
     * models the wipe so that moving it back would fail here rather than on a student's laptop.
     * The real one exits 0 whether or not the instance was running (measured both ways).
     *
     * NO --no-distribution / --shutdown ARM: nothing in the .cmd uses either. */
    if (has(argc, argv, "--terminate")) {
        const char *name = argv[argc - 1];
        if (!registered(name)) {
            char body[4096], code[512];
            if (!fake_msg("MessageDistroNotFound", body, sizeof body)
                || !fake_msg("ErrorCodeDistroNotFound", code, sizeof code)) {
                fprintf(stderr, "win-fake: --terminate on an absent distro needs both "
                                "MessageDistroNotFound and ErrorCodeDistroNotFound\n");
                return 120;
            }
            fake_say(stdout, "MessageErrorCode", body, code);
            return WSL_FAIL;
        }
        long rc = fake_knob_int("wsl.terminate.rc", 0);
        /* EXITS 0 WITHOUT RESTARTING ANYTHING, which is not a hypothetical: `wsl --manage
         * --set-default-user` terminates the instance only `if (modified)`, so the obvious
         * alternative to this call really does no-op on a re-run where the value is already
         * right. The .cmd's handover check is what has to notice, and this is how that arm is
         * reached. */
        if (rc == 0 && fake_knob_int("wsl.terminate.noop", 0)) {
            fake_say(stdout, "SystemErrorSuccess", NULL, NULL);
            return 0;
        }
        if (rc == 0) {
            touch_marker("wsl.terminated");
            if (stage2_is_in_tmp()) remove_marker("stage2.sh");
            fake_say(stdout, "SystemErrorSuccess", NULL, NULL);
        }
        return (int)rc;
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

    /* EVERY ARM BELOW RUNS INSIDE A DISTRO, so the one named by `-d` has to be there. The real
     * wsl.exe throws WSL_E_DISTRO_NOT_FOUND here and prints it -- to STDOUT, like all its errors.
     * No case reaches this today, because the .cmd probes before it uses the distro; the guard
     * exists so that a version which stops probing fails HERE rather than somewhere downstream
     * with a message about the network. */
    /* WITH THE ENVELOPE, because that is what the real one does -- transcribed from WSL 2.7.12:
     *
     *     There is no distribution with the supplied name.
     *     Error code: Wsl/Service/WSL_E_DISTRO_NOT_FOUND
     *
     * It printed the body alone until that was measured. The difference matters because the
     * `Error code:` line is exactly what the refusals now ask students to send staff, so a fake
     * that omitted it would let a message claiming to carry one pass without one. */
    if (dashd(argc, argv) && !registered(dashd(argc, argv))) {
        char body[4096], code[512];
        if (!fake_msg("MessageDistroNotFound", body, sizeof body)
            || !fake_msg("ErrorCodeDistroNotFound", code, sizeof code)) {
            fprintf(stderr, "win-fake: -d on an absent distro needs both MessageDistroNotFound "
                            "and ErrorCodeDistroNotFound\n");
            return 120;
        }
        fake_say(stdout, "MessageErrorCode", body, code);
        return WSL_FAIL;
    }

    /* ...AND EVERY ARM BELOW NEEDS THE UTILITY VM, so on a machine that cannot start one they all
     * fail. That is the SECOND site issue #114 is about, and the one #112's fix never reached: the
     * environment already exists, so the create is skipped entirely, and the .cmd used to arrive
     * at :curlfailed and tell the student the network was not up yet inside it.
     *
     * THE PROSE IS ATTESTED AND THE SCOPE CHAIN IS NOT, which is why this prints one and not the
     * other. MessageEnableVirtualization is the resource string wsl.exe emits whenever it cannot
     * start a VM, whatever the operation asked for, so printing it here is transcription. The
     * `Error code:` chain for `-d` on such a machine has never been captured -- reusing
     * --install's would be inventing it, and a chain invented for one operation out of another's
     * is a mistake this fixture has made before. MANUAL.md carries the transcription as a
     * hardware item,
     * and if it turns out to carry HCS_E_HYPERV_NOT_INSTALLED too then the .cmd's classifier
     * starts routing this site to :novm with no change here. */
    if (fake_knob_int("wsl.vm.cannotstart", 0)) {
        fake_say(stdout, "MessageEnableVirtualization", NULL, NULL);
        return WSL_FAIL;
    }
    /* `-u root -e mv /etc/wsl-distribution.conf /etc/wsl-distribution.conf.cs193v`: Ubuntu's
     * first-run setup, switched off before there is an account gap for a student to fall into.
     * --no-launch has already created the Start Menu entry, so for as long as the setup is armed
     * a click on it fires the questions -- and the .cmd's next `-e` call would then block on an
     * event with no timeout.
     *
     * mv RATHER THAN truncate IS THE POINT BEING MODELLED. truncate creates the file if it is
     * absent and exits 0, so the day Canonical moves that configuration the suppression becomes
     * a silent no-op; mv fails. So this arm fails the second time too, exactly as the real one
     * does -- measured on 2026-09-10, `mv: cannot stat ...`, rc 1 -- which is what asserts that
     * the .cmd only does this on the path where the environment was just created.
     *
     * wsl.oobe.conf.missing IS THE CANONICAL-MOVED-IT CASE, and the reason the root pass has a
     * refusal of its own to reach. */
    if (has(argc, argv, "mv")) {
        const char *src = argc > 1 ? argv[argc - 2] : "";
        if (fake_knob_int("wsl.oobe.conf.missing", 0) || exists("oobe.moved")) {
            fake_say(stdout, "MvCannotStat", src, NULL);
            return 1;
        }
        touch_marker("oobe.moved");
        return 0;
    }

    /* `-u root -e getent passwd student` and `... getent passwd 1000`: does this environment
     * already have an account, and is it ours? The .cmd branches three ways on the exit code --
     * 0 present, 2 absent, anything else the question itself failed -- so both codes are real
     * here. Measured on 2026-09-10: 0 present, 2 absent, no output either way.
     *
     * THE STATE IS THE MARKERS, so a distro provisioned earlier in the same case answers 0 and a
     * fresh one answers 2. wsl.account.foreign NAMES A HUMAN ACCOUNT THAT IS NOT OURS, which is
     * the shape of a CS193V made by the installer that asked students to choose a username: the
     * uid-1000 probe answers 0 while the `student` probe answers 2, and the .cmd owes that state
     * a refusal rather than a second account. */
    if (has(argc, argv, "getent")) {
        char foreign[128];
        const char *key = argv[argc - 1];
        int have_ours = exists("account.student");
        int have_foreign = fake_knob("wsl.account.foreign", foreign, sizeof foreign) && foreign[0];
        if (strcmp(key, "1000") == 0) return (have_ours || have_foreign) ? 0 : 2;
        if (have_ours && strcmp(key, "student") == 0) return 0;
        if (have_foreign && strcmp(key, foreign) == 0) return 0;
        return 2;
    }

    /* `-e test -O /home/student`: THE HANDOVER, ASKED RATHER THAN ASSUMED. "Is that directory
     * owned by the user I am running as?" is the one question that proves the whole provisioning
     * sequence worked -- the account exists, /etc/wsl.conf names it, and the instance has
     * restarted so that stanza is in effect. Which is why this is 0 only once BOTH markers are
     * there: before the terminate the default user is still root, and the real `test -O` returns
     * 1 (measured, both ways, on 2026-09-10). */
    if (has(argc, argv, "test") && has(argc, argv, "-O")) {
        return (exists("account.student") && exists("wsl.terminated")) ? 0 : 1;
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
     * the grep arm below then reads, so the two are not independently stubbed.
     *
     * AND THE DESTINATION IS RECORDED, because one property of it is load-bearing: /tmp inside a
     * systemd WSL instance is a tmpfs, and the .cmd restarts the instance between this download
     * and the run. --terminate reads this and wipes the file if it landed under /tmp. */
    if (has(argc, argv, "curl")) {
        long rc = fake_knob_int("wsl.curl.rc", 0);
        int i;
        for (i = 1; i < argc - 1; i++)
            if (strcmp(argv[i], "-o") == 0) { write_marker("stage2.dest", argv[i + 1]); break; }
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

    /* THE TWO STAGE-2 CALLS, TOLD APART BY THE ENVIRONMENT VARIABLE (#217). The .cmd runs the
     * same downloaded script twice: once as `-u root -e env CS193V_PROVISION=1 bash <path>`, the
     * root pass, and once as `-e bash <path>`, the pass a student watches. They are two different
     * things that can fail differently, so they get two exit codes and the first one leaves a
     * marker the getent and `test -O` arms read.
     *
     * MATCHED ON THE ASSIGNMENT AS A WHOLE, because that is the argv the .cmd really passes and
     * `has()` compares whole arguments. A .cmd that stopped setting it would fall through to the
     * student arm and the account marker would never appear, which the handover check then
     * catches. */
    if (has(argc, argv, "bash")) {
        int provisioning = has(argc, argv, "CS193V_PROVISION=1");
        /* WHAT bash DOES WITH A PATH THAT IS NOT THERE, and it is here because /tmp inside a
         * systemd WSL instance is a tmpfs: a .cmd that downloaded stage 2 to /tmp and then
         * restarted the instance would hand this arm a file --terminate has already wiped.
         * Attested on 2026-09-10: `bash: <path>: No such file or directory`, rc 127. */
        const char *script = argv[argc - 1];
        if (!exists("stage2.sh")) {
            fake_say(stdout, "BashNoSuchFile", script, NULL);
            return 127;
        }
        /* A VISIBLE boundary, not install-cs193v.sh's transcript. That script is this repo's own
         * and has its own coverage; reproducing its output here would be inventing prose and
         * duplicating tests. Printing nothing was worse: the handoff looked like it had not
         * happened at all. */
        if (fake_knob_int("wsl.stage2.quiet", 0) == 0)
            fake_say(stdout, provisioning ? "ProvisionBoundary" : "Stage2Boundary", NULL, NULL);
        if (provisioning) {
            long rc = fake_knob_int("wsl.provision.rc", 0);
            /* THE ACCOUNT REALLY APPEARS, so what follows is a sequence rather than a set of
             * independent answers: getent then says yes, and `test -O` says yes once the
             * instance has also been restarted. */
            if (rc == 0) touch_marker("account.student");
            return (int)rc;
        }
        return (int)fake_knob_int("wsl.bash.rc", 0);
    }

    fake_say(stdout, "MessageInvalidCommandLine", argc > 1 ? argv[1] : "", "wsl.exe");
    return WSL_FAIL;
}

/* Shared plumbing for the Windows-side fakes.
 *
 * WHY FOUR PROGRAMS AND NOT ONE. wsl.exe, net.exe, where.exe and powershell.exe have genuinely
 * different observable contracts: wsl emits UTF-16LE by default, routes its ERRORS TO STDOUT and
 * fails with -1; where splits stdout/stderr and uses 0/1; net has three codes with distinct
 * text; powershell derives its code from $? and collapses native codes to 1. Multiplexing those
 * on argv[0] would make encoding, stream routing and exit convention all conditional on a
 * string, leaving one fake structurally ABLE to apply wsl's -1 convention to where -- the
 * opposite of what lib/sudo-fake buys by having no exec branch at all. So: one source per tool,
 * and only the mechanism below is shared.
 *
 * NO PROSE LIVES IN THESE PROGRAMS. Every student-visible string is looked up by key from
 * fixtures/wsl-messages.<version>, so the provenance of each one stays auditable and a WSL
 * version bump is a fixture edit. See the header of that file for the A/B/C tiers.
 *
 * The knob-file-and-argv-log shape is lib/podman-fake's, deliberately: a case configures the
 * fake by writing files, and asserts on what was really called by reading argv.log.
 */
#ifndef WIN_FAKE_H
#define WIN_FAKE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Every path the fakes touch lives under this directory, handed in as a Windows path. */
static inline const char *fake_dir(void) {
    const char *d = getenv("CS193V_FAKE_DIR");
    return d ? d : "C:\\fake";
}

static inline void fake_path(char *out, size_t n, const char *leaf) {
    snprintf(out, n, "%s\\%s", fake_dir(), leaf);
}

/* Append the full command line, so a case can assert WHAT was called with WHICH arguments and
 * not merely that something happened. One line per invocation, argv[0] reduced to its basename
 * so the log does not depend on where the shim directory happens to be. */
static inline void fake_log_argv(int argc, char **argv) {
    char p[1024]; FILE *f;
    fake_path(p, sizeof p, "argv.log");
    if (!(f = fopen(p, "a"))) return;
    const char *base = argv[0], *q;
    for (q = argv[0]; *q; q++) if (*q == '\\' || *q == '/') base = q + 1;
    fputs(base, f);
    for (int i = 1; i < argc; i++) { fputc(' ', f); fputs(argv[i], f); }
    fputc('\n', f);
    fclose(f);
}

/* A knob is a file whose name is the question and whose first line is the answer. Absent means
 * "the default", which for every knob here is the success case -- so a test writes only the
 * knobs whose behaviour it is actually varying. */
static inline int fake_knob(const char *name, char *out, size_t n) {
    char p[1024]; FILE *f; size_t len;
    fake_path(p, sizeof p, name);
    if (!(f = fopen(p, "rb"))) return 0;
    if (!fgets(out, (int)n, f)) { fclose(f); out[0] = '\0'; return 1; }
    fclose(f);
    len = strlen(out);
    while (len && (out[len-1] == '\n' || out[len-1] == '\r')) out[--len] = '\0';
    return 1;
}

static inline long fake_knob_int(const char *name, long dflt) {
    char buf[64];
    if (!fake_knob(name, buf, sizeof buf) || !buf[0]) return dflt;
    return strtol(buf, NULL, 10);
}

/* Look a message up by key. Returns 0 if the key is absent -- callers must treat that as a hard
 * error rather than printing nothing, because a silently missing message would let a case pass
 * while asserting on text that was never emitted. */
static inline int fake_msg(const char *key, char *out, size_t n) {
    char p[1024], line[4096];
    FILE *f;
    fake_path(p, sizeof p, "messages");
    if (!(f = fopen(p, "rb"))) return 0;
    size_t klen = strlen(key);
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue;
        if (strncmp(line, key, klen) != 0 || line[klen] != '\t') continue;
        char *tier = line + klen + 1;
        char *text = strchr(tier, '\t');
        if (!text) break;
        text++;
        /* expand the literal \n the table uses so it can keep one message per line */
        size_t o = 0;
        for (char *s = text; *s && o + 1 < n; s++) {
            if (*s == '\\' && s[1] == 'n') { out[o++] = '\n'; s++; }
            else if (*s == '\n' || *s == '\r') continue;
            else out[o++] = *s;
        }
        out[o] = '\0';
        fclose(f);
        return 1;
    }
    fclose(f);
    return 0;
}

/* Substitute the {} placeholders, left to right. */
static inline void fake_fmt(char *buf, size_t n, const char *a, const char *b) {
    const char *args[2] = { a, b };
    char out[4096]; size_t o = 0; int used = 0;
    for (const char *s = buf; *s && o + 1 < sizeof out; s++) {
        if (s[0] == '{' && s[1] == '}' && used < 2 && args[used]) {
            const char *v = args[used++];
            while (*v && o + 1 < sizeof out) out[o++] = *v++;
            s++;
        } else out[o++] = *s;
    }
    out[o] = '\0';
    snprintf(buf, n, "%s", out);
}

/* Emit a message by key, or die loudly. `stream` is stdout for everything wsl.exe says --
 * including its errors, which is not a mistake but the behaviour that makes an unvalidated
 * `for /f` capture pick up an error string as if it were a value. */
static inline void fake_say(FILE *stream, const char *key, const char *a, const char *b) {
    char msg[4096];
    if (!fake_msg(key, msg, sizeof msg)) {
        fprintf(stderr, "win-fake: no message keyed '%s' in %s\\messages\n", key, fake_dir());
        exit(120);
    }
    fake_fmt(msg, sizeof msg, a, b);
    fprintf(stream, "%s\n", msg);
}

/* wsl.exe switches its whole CRT to UTF-16 unless WSL_UTF8 is exactly "1" -- stdout AND stderr,
 * no BOM. Reproducing that is the point: the .cmd routes `wsl -l -q` through PowerShell BECAUSE
 * batch cannot read UTF-16, and a fake that emitted ASCII would let a change deleting that hop
 * pass. Measured under wine: `for /f` reads one byte pair and stops. */
static inline int fake_wsl_utf8(void) {
    const char *v = getenv("WSL_UTF8");
    return v && strcmp(v, "1") == 0;
}

static inline void fake_write_line(const char *s) {
    if (fake_wsl_utf8()) {
        printf("%s\n", s);
        return;
    }
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        fputc(*p, stdout);
        fputc(0, stdout);
    }
    fputc('\r', stdout); fputc(0, stdout);
    fputc('\n', stdout); fputc(0, stdout);
}

#endif

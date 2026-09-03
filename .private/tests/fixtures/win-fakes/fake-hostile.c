/* The planted binary, for the one case that asserts it never runs (issue #125).
 *
 * WHY THIS IS NOT A KNOB ON ANOTHER FAKE. Every other program here stands in for something the
 * installer MEANS to call. This one stands in for something it must not: a copy of wsl.exe,
 * reg.exe, where.exe or powershell.exe that an attacker left in the student's download folder
 * before the installer ever ran. lib/wine.sh copies it in under all four of those names, so the
 * only thing distinguishing it from the real fakes at run time is what it writes -- which is why
 * it cannot be an arm of fake-wsl.c keyed on argv[0].
 *
 * IT LOGS A TOKEN AND NOT ITS OWN NAME. fake_log_argv reduces argv[0] to a basename, so a hostile
 * copy called wsl.exe would log a line indistinguishable from the legitimate fake's. HIJACKED is
 * therefore written verbatim, and 27-installer-windows.sh counts occurrences of it. Paired in that
 * case with a positive count of the real programs, because zero of something is an absence and an
 * absence is what a harness failure also looks like.
 *
 * IT EXITS 0 AND SAYS NOTHING ELSE. A hostile binary that failed loudly would let the installer
 * fall into an error arm and the case would go green for the wrong reason -- the run has to look
 * ordinary so that "the planted copy never ran" is the only thing the assertion can be measuring.
 */
#include "win-fake.h"

int main(int argc, char **argv) {
    char p[1024];
    FILE *f;
    fake_path(p, sizeof p, "argv.log");
    if ((f = fopen(p, "a"))) {
        const char *base = argv[0], *q;
        for (q = argv[0]; *q; q++) if (*q == '\\' || *q == '/') base = q + 1;
        fputs("HIJACKED ", f);
        fputs(base, f);
        for (int i = 1; i < argc; i++) { fputc(' ', f); fputs(argv[i], f); }
        fputc('\n', f);
        fclose(f);
    }
    return 0;
}

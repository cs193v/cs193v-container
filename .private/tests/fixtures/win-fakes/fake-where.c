/* where.exe. Exit 0 and the path on stdout when found; exit 1 and a message on STDERR when not.
 * The stream split is the part that matters: a caller redirecting only stdout still sees the
 * error, and `>nul 2>&1` is required to silence it.
 *
 * Which names "exist" is one knob per name, so a case says exactly what the machine has.
 */
#include "win-fake.h"

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);
    if (argc < 2) return 1;
    /* wine's own where.exe rejects every /switch; the .cmd passes none, and neither do we. */
    char knob[256], val[256];
    snprintf(knob, sizeof knob, "where.%s", argv[1]);
    if (fake_knob(knob, val, sizeof val) && strcmp(val, "0") == 0) {
        fake_say(stderr, "WhereNotFound", NULL, NULL);
        return 1;
    }
    printf("C:\\Windows\\System32\\%s\n", argv[1]);
    return 0;
}

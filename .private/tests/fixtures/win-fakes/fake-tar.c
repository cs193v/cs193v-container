/* tar.exe, which Windows has shipped in system32 since 10/1803 and the gate uses to build the
 * 1.5 KB payload it hands to `wsl --import`.
 *
 * WHY A FAKE AT ALL, when the real one is in the wine image: because the gate's THREE outcomes
 * have to be arrangeable, and "tar is here but cannot write" is one of them. It is also the only
 * way a case can prove the .cmd treats a payload it could not build as a FAILED CHECK rather than
 * as a machine that cannot start a VM -- the distinction issue #114 is about.
 *
 * It writes a real file rather than pretending to, because the .cmd hands that path to wsl.exe
 * and a fake that wrote nothing would make the import arm's own behaviour untestable.
 */
#include "win-fake.h"

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);
    long rc = fake_knob_int("tar.rc", 0);
    if (rc != 0) return (int)rc;
    /* -cf <file>: the archive is argv[2] in every call the .cmd makes. Not a general tar. */
    if (argc < 3) return 1;
    FILE *f = fopen(argv[2], "wb");
    if (!f) return 1;
    /* A tar of one empty directory is 1536 bytes of header plus padding on the real thing; the
     * content is never read by anything here, only its existence and size. */
    static const char blank[1536];
    fwrite(blank, 1, sizeof blank, f);
    fclose(f);
    return 0;
}

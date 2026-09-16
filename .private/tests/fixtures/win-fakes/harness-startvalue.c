/* startvalue.exe -- NOT A FAKE. It is the harness standing in for WINDOWS, and it is in this
 * directory because this is where the PE binaries the wine fixture compiles live.
 *
 * WHAT IT IS FOR. Since #275 the installer registers a RunOnce value, and the case that matters
 * runs THAT VALUE rather than running the .cmd a second time -- otherwise the test says the
 * installer is idempotent, which was already true and already covered, and says nothing about
 * whether the thing handed to Windows is a thing Windows could start. The quoting in that value
 * is the part most likely to be wrong.
 *
 * WHY IT HAD TO EXIST, WHICH IS A MEASUREMENT AND NOT A PREFERENCE. The obvious way to run the
 * value is `wine64 cmd /c "$value"` from the container script. That does not work, and the way
 * it fails is quiet: wine converts a Unix argv into a Windows command line by ESCAPING the
 * quotes inside each argument, so the inner cmd.exe receives \" \" where the value had " ", and
 * reports `Can't recognize '\"\"Z:\...\"\"' as an internal or external command` with exit 49.
 * Measured in the fixture on 2026-09-16. Every spelling of the value fails that way, including
 * the ones that are correct -- so a case built on that wrapper would have been testing wine's
 * argv conversion and would have gone red for a correct installer.
 *
 * SO IT DOES WHAT WINDOWS DOES. A Run/RunOnce value is handed to CreateProcess as lpCommandLine
 * with lpApplicationName NULL, and CreateProcess parses the program out of the front of it
 * itself. That is one call, it is the same call, and it takes the line verbatim -- no argv round
 * trip and no shell in between.
 *
 * THE LINE COMES FROM A FILE, argv[1], for the same reason: passing it as an argument would put
 * it back through the escaping this exists to avoid.
 *
 * WHAT IS STILL NOT WINDOWS, and it belongs in MANUAL.md rather than in a comment that claims
 * otherwise: the process this starts is wine's cmd.exe, and wine's cmd does not handle `&`
 * inside the quotes that /S leaves behind. Measured the same day -- a download folder under an
 * account called `Tom & Jerry` splits at the ampersand under wine and does not on Windows, where
 * the quotes protect it. So the tier proves the value starts; it does not prove it starts for
 * every profile name, and no tier can.
 */
#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv) {
    char line[8192];
    FILE *f;
    size_t n;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD code = 0;

    if (argc < 2) {
        fprintf(stderr, "startvalue: usage: startvalue <file holding the command line>\n");
        return 96;
    }
    if (!(f = fopen(argv[1], "rb"))) {
        fprintf(stderr, "startvalue: cannot read %s\n", argv[1]);
        return 96;
    }
    n = fread(line, 1, sizeof line - 1, f);
    fclose(f);
    line[n] = '\0';
    while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
    /* An empty value is a HARNESS failure and must not look like a program that ran and printed
     * nothing -- the case asserting on the second run would otherwise pass for free. */
    if (!n) {
        fprintf(stderr, "startvalue: %s held no command line\n", argv[1]);
        return 96;
    }

    ZeroMemory(&si, sizeof si);
    si.cb = sizeof si;
    ZeroMemory(&pi, sizeof pi);
    /* lpApplicationName NULL and the whole line as lpCommandLine: this is the shape Windows uses
     * for a Run/RunOnce value, and the shape that makes CreateProcess find the program itself.
     * Handles are inherited so the child's output reaches the container's redirection. */
    if (!CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "startvalue: CreateProcess refused the line (error %lu): %s\n",
                (unsigned long)GetLastError(), line);
        return 95;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}

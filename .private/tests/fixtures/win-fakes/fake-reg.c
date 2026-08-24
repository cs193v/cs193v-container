/* reg.exe, for the `reg query "HKU\S-1-5-19"` elevation probe only.
 *
 * The probe reads the LOCAL SERVICE hive, which only an elevated process can open, so the whole
 * observable contract is one exit code: 0 elevated, non-zero not. The real one prints an
 * ERROR: line on failure, but the installer sends both streams to nul, so no message is modelled
 * -- and that is deliberate. A fake that invented prose nobody asserts on would be one more
 * unsourced string in a file whose whole point is that every string has a provenance.
 */
#include "win-fake.h"

int main(int argc, char **argv) {
    fake_log_argv(argc, argv);
    return (int)fake_knob_int("reg.query.rc", 0);
}

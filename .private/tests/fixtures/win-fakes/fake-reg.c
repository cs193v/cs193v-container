/* reg.exe, for the `reg query "HKU\S-1-5-19"` elevation probe only.
 *
 * The probe reads the LOCAL SERVICE hive, which only an elevated process can open, so the whole
 * observable contract is one exit code: 0 elevated, non-zero not. The real one prints an
 * ERROR: line on failure, but the installer sends both streams to nul, so no message is modelled
 * -- and that is deliberate. A fake that invented prose nobody asserts on would be one more
 * unsourced string in a file whose whole point is that every string has a provenance.
 */
#include "win-fake.h"

/* THE DEFAULT IS NOT-ELEVATED, AND IT USED TO BE THE OTHER WAY ROUND. It was 0 -- elevated --
 * back when the installer REQUIRED elevation, so that every case in the tier described a run that
 * could get past the front door. The installer now REFUSES an elevated run, so a default of 0
 * would make every case in the tier describe the one invocation students are told not to use,
 * and the whole suite would assert against a refusal. 1 is the ordinary run: a student
 * double-clicking the file as themselves. Cases that want the refusal ask for it with
 * `reg.query.rc 0`, which is exactly one case -- win-isadmin.
 */
int main(int argc, char **argv) {
    fake_log_argv(argc, argv);
    return (int)fake_knob_int("reg.query.rc", 1);
}

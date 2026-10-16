#!/usr/bin/env bash
# TIER: unit
#
# The watcher's /proc/net/tcp parse, fuzzed. No podman, no container, no /proc.
#
# WHY THIS IS FUZZED AT ALL, when the input comes from the kernel and not from a student. Two
# reasons. The format is stable but not frozen -- a field added to the end, a v6 form we did not
# anticipate -- and a misparse here is silent: it does not crash, it forwards the wrong port or
# quietly forwards nothing. And the classifier is where a bug costs a student a WRONG DIAGNOSIS
# rather than no diagnosis, which this project treats as the worse failure.
#
# It also earns its place historically: the four-class table this replaced was wrong. Real kernel
# data on the development machine had systemd-resolved on 127.0.0.53, which the table sent to
# `eth` -- so a student would have been told "bound to the container's network interface" about an
# address that is loopback. `loalt` exists because of that, and these cases pin it.
#
# SOURCED, like 12-run-timeout.sh and 17-portparse-fuzz.sh. The parse takes TEXT rather than
# reading /proc itself, precisely so it can be driven with synthetic input from a host that has no
# container -- and so the unit tier can hold it. cs193v-portwatch must therefore stay parseable
# under bash 3.2: the TAs run this tier on Macs.

set -u
. "$(dirname -- "$0")/lib/assert.sh"

cd "$REPO" || exit 1

# THIS RUN'S OWN SCRATCH, not a fixed name in /tmp (#379). /tmp is one directory for every developer
# on the machine, so /tmp/pwstate.txt was one file for every concurrent run of this suite: one run
# read another's --show fixture as its round trip, or found it deleted.
#
# CHECKED, because a redirect that cannot open its file never runs its command: feed() below would
# then pass the garbage check having scanned nothing. Removed at the end of the file rather than
# from an EXIT trap, which would replace the one lib/assert.sh sets to print a direct run's summary.
WORK="$(new_tmpdir)"
if [ -d "$WORK" ] && [ -w "$WORK" ]; then
    pass "pw:has-a-scratch-directory-of-its-own"
else
    fail "pw:has-a-scratch-directory-of-its-own" "new_tmpdir gave '$WORK' under TMPDIR=${TMPDIR:-}"
    exit 1
fi

# Read by the source guard at the bottom of cs193v-portwatch, which the `.` three lines below brings
# in -- a `.` shellcheck does not follow without -x, and -x here would resolve the source and hide
# every finding this file has.
# shellcheck disable=SC2034
CS193V_PORTWATCH_SOURCED=1
# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=.private/files/cs193v-portwatch
. "$PRIVATE/files/cs193v-portwatch"

if ! command -v pw_scan_text >/dev/null 2>&1; then
    fail "pw:the-parser-exists" \
"pw_scan_text is not defined in files/cs193v-portwatch.
Every assertion in this suite drives it, so there is nothing to test."
    exit 1
fi
pass "pw:the-parser-exists"

# A /proc/net/tcp header, byte-identical to the kernel's, because the parser must skip it.
HDR='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
row() { printf '%4s: %s %s %s 00000000:00000000 00:00000000 00000000  1000        0 0 1 0000 0 0 0 0 0\n' "$1" "$2" "$3" "$4"; }

# ─── the classifier, against addresses taken from real kernel output ───────────
# Every v4 value below was observed on a live machine; the v6 ones are constructed from the
# documented layout (four 32-bit words, each little-endian) and the ::1 case was observed.
one() {                               # one V4ROWS V6ROWS -> $PW_SET
    pw_scan_text "$1" "$2"
}
cls_is() {                            # cls_is NAME EXPECT V4 V6
    one "$3" "$4"
    assert_eq "pw:class:$1" "$2" "$PW_SET"
}
cls_is "loopback-exact"  "3000:lo"    "$HDR
$(row 0 0100007F:0BB8 00000000:0000 0A)" "$HDR"
cls_is "wildcard"        "3000:any"   "$HDR
$(row 0 00000000:0BB8 00000000:0000 0A)" "$HDR"
# 127.0.0.53 -- systemd-resolved. The bug that created the loalt class: a four-class table called
# this `eth` and would have told a student it was bound to a network interface.
cls_is "alt-loopback-53" "53:loalt"   "$HDR
$(row 0 3500007F:0035 00000000:0000 0A)" "$HDR"
cls_is "alt-loopback-2"  "3000:loalt" "$HDR
$(row 0 0200007F:0BB8 00000000:0000 0A)" "$HDR"
cls_is "real-interface"  "3000:eth"   "$HDR
$(row 0 0101A8C0:0BB8 00000000:0000 0A)" "$HDR"
cls_is "v6-any"          "3000:any"   "$HDR" "$HDR
$(row 0 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A)"
cls_is "v6-loopback"     "631:v6lo"   "$HDR" "$HDR
$(row 0 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A)"
cls_is "v6-mapped-lo"    "3000:lo"    "$HDR" "$HDR
$(row 0 0000000000000000FFFF00000100007F:0BB8 00000000000000000000000000000000:0000 0A)"
cls_is "v6-mapped-any"   "3000:any"   "$HDR" "$HDR
$(row 0 0000000000000000FFFF000000000000:0BB8 00000000000000000000000000000000:0000 0A)"
cls_is "v6-real"         "3000:eth"   "$HDR" "$HDR
$(row 0 FE800000000000000000000000000001:0BB8 00000000000000000000000000000000:0000 0A)"

# ─── only LISTEN counts ────────────────────────────────────────────────────────
# st 01 is ESTABLISHED, 06 TIME_WAIT, 0A LISTEN. Forwarding an established socket's local port
# would bind a host port for a connection, not a server.
one "$HDR
$(row 0 0100007F:0BB8 0100007F:9999 01)
$(row 1 0100007F:1F90 00000000:0000 0A)
$(row 2 0100007F:2710 0100007F:8888 06)" "$HDR"
assert_eq "pw:only-listen-sockets-count" "8080:lo" "$PW_SET"

# ─── the per-port merge: most reachable wins ───────────────────────────────────
# A port appears more than once under dual-stack, SO_REUSEPORT, or one process on lo and another
# elsewhere. Observed live: cups on 631 as both 127.0.0.1 and ::1. The host's only question is
# "can the tunnel reach it", so if ANY socket on that port is reachable, the port is.
one "$HDR
$(row 0 0100007F:0277 00000000:0000 0A)" "$HDR
$(row 0 00000000000000000000000001000000:0277 00000000000000000000000000000000:0000 0A)"
assert_eq "pw:merge-lo-beats-v6lo" "631:lo" "$PW_SET"
one "$HDR
$(row 0 0101A8C0:0BB8 00000000:0000 0A)
$(row 1 00000000:0BB8 00000000:0000 0A)" "$HDR"
assert_eq "pw:merge-any-beats-eth" "3000:any" "$PW_SET"
one "$HDR
$(row 0 3500007F:0BB8 00000000:0000 0A)
$(row 1 0100007F:0BB8 00000000:0000 0A)" "$HDR"
assert_eq "pw:merge-lo-beats-loalt" "3000:lo" "$PW_SET"

# ─── output is sorted and deduped, so a frame is stable tick to tick ───────────
# /proc order is by hash bucket. Relying on it being stable would be the accidental correctness
# this design avoids elsewhere, and an unstable order makes the host cancel and re-forward a set
# that has not changed.
one "$HDR
$(row 0 0100007F:1F90 00000000:0000 0A)
$(row 1 0100007F:0BB8 00000000:0000 0A)
$(row 2 0100007F:2710 00000000:0000 0A)" "$HDR"
assert_eq "pw:output-is-sorted" "3000:lo 8080:lo 10000:lo" "$PW_SET"

# ─── the cost of a scan grows with the table, not with its square  (#337) ──────
# /proc/net/tcp lists EVERY socket in the netns, not just listeners, and TIME_WAIT alone keeps a
# closed connection in it for 60 s -- a Playwright run leaves ~6-11 lines per test. The scan used
# to peel one line off the front of the text per iteration, copying everything after it each
# time, so a tick cost the SQUARE of the table: 6.5 s at 1000 lines in the container, 25.7 s at
# 2000, and past 30 s the supervisor declared the watcher dead for the rest of the session.
#
# A RATIO, NOT A BOUND. The constant moves with the machine and the locale -- the old code was
# ~5x slower under the image's en_US.UTF-8 than under C -- while the shape does not: four times
# the rows costs ~4x linear and ~16x quadratic whatever the constant. The minimum of three runs,
# because a loaded machine only ever adds time. The absolute ceiling beside it catches a linear
# scan that has merely become expensive.
#
# FAIL FAST ON THE SMALL TABLE, so a red run is seconds rather than minutes: the old code took
# ~1.8 s for 500 of these rows under UTF-8, and ~5 s per 2000-row run under C.
#
# ONE awk FOR THE WHOLE TABLE, not a $(row) per line -- that would be 4000 forks per run.
pw_table() {                          # pw_table ROWS v4|v6 -> a /proc/net/tcp{,6}-shaped table
    do_awk -v n="$1" -v fam="$2" -v hdr="$HDR" 'BEGIN {
        print hdr
        lo = (fam == "v4") ? "0100007F" : "0000000000000000FFFF00000100007F"
        for (i = 0; i < n - 2; i++)
            printf "%4d: %s:%04X %s:%04X %s 00000000:00000000 00:00000000 00000000  1000        0 0 1 0000 0 0 0 0 0\n",
                   i, lo, 32768 + (i * 7) % 28000, lo, 5173, (i % 7 == 0) ? "01" : "06"
        # A TIME_WAIT whose own port is 0A0A: whatever skips lines cheaply, it is the state
        # field that has to decide.
        printf "%4d: %s:0A0A %s:1F90 06 00000000:00000000 00:00000000 00000000  1000        0 0 1 0000 0 0 0 0 0\n", n - 2, lo, lo
        # The ONLY listener, and it is the last line: nothing may stop early.
        if (fam == "v4")
            printf "%4d: %s:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 0 1 0000 0 0 0 0 0\n", n - 1, lo
        else
            printf "%4d: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 0 1 0000 0 0 0 0 0\n", n - 1
    }'
}
PW_T4_500="$(pw_table 500 v4)";   PW_T6_500="$(pw_table 500 v6)"
PW_T4_2000="$(pw_table 2000 v4)"; PW_T6_2000="$(pw_table 2000 v6)"
scan_small() { pw_scan_text "$PW_T4_500" "$PW_T6_500"; }
scan_large() { pw_scan_text "$PW_T4_2000" "$PW_T6_2000"; }
fastest_of_3() {                      # fastest_of_3 FN -> the least of three elapsed times
    local a b c
    a="$(elapsed "$1")"; b="$(elapsed "$1")"; c="$(elapsed "$1")"
    printf '%s\n%s\n%s\n' "$a" "$b" "$c" | sort -n | head -1
}

# THE ANSWER FIRST, in this shell rather than elapsed's subshell, because a fast scan that
# returns the wrong set is not a fix. The small table has the same last-row listener and the
# same 0A0A TIME_WAIT, and on the old code it costs seconds where the large one costs a minute.
scan_small
assert_eq "pw:a-large-table-yields-exactly-its-listeners" "3000:lo 8080:any" "$PW_SET"

PW_TS="$(elapsed scan_small)"
if ! faster_than 0.5 "$PW_TS"; then
    record "pw:seconds-to-scan-1000-lines" "$PW_TS"
    fail "pw:scan-cost-grows-linearly-with-the-table" "one scan of 2 x 500 rows took ${PW_TS}s,
which is quadratic territory (#337); a linear scan does it in a few hundredths. Not timing the
2000-row table, which would take minutes."
    fail "pw:a-large-table-scans-in-under-a-second" "see above"
else
    PW_TS="$(fastest_of_3 scan_small)"; PW_TL="$(fastest_of_3 scan_large)"
    record "pw:seconds-to-scan-1000-lines" "$PW_TS"
    record "pw:seconds-to-scan-4000-lines" "$PW_TL"
    # The floor keeps a 1 ms clock from dividing by zero on a fast machine; it cannot make a
    # linear ratio look quadratic, because a 4x table under 4 ms is under 16 ms.
    PW_RATIO="$(awk -v s="$PW_TS" -v l="$PW_TL" 'BEGIN { if (s < 0.004) s = 0.004; printf "%.1f", l / s }')"
    record "pw:scan-cost-ratio-for-4x-the-rows" "$PW_RATIO"
    if faster_than 8 "$PW_RATIO"; then
        pass "pw:scan-cost-grows-linearly-with-the-table"
    else
        fail "pw:scan-cost-grows-linearly-with-the-table" "4x the rows cost ${PW_RATIO}x the time
(${PW_TS}s -> ${PW_TL}s). Linear is ~4x; the peel loop #337 removed was ~16x."
    fi
    if faster_than 1 "$PW_TL"; then
        pass "pw:a-large-table-scans-in-under-a-second"
    else
        fail "pw:a-large-table-scans-in-under-a-second" "2 x 2000 rows took ${PW_TL}s at best of three."
    fi
fi

# ─── ...and the split that made it linear changes nothing else ─────────────────
# The scan now splits the whole table on newlines and word-splits each line itself, so the
# caller's IFS, noglob and locale are the scan's business only while it runs.
#
# A GLOB CHARACTER IN A FIELD. The old per-line `set -- $line` globbed: a lone `*` field expanded
# to every file in the current directory, shifted the fields, and the row was silently dropped --
# an answer that depended on where the watcher happened to be standing.
one "$HDR
   * 0100007F:0BB8 00000000:0000 0A x" "$HDR"
assert_eq "pw:a-glob-character-in-a-field-is-not-expanded" "3000:lo" "$PW_SET"
# A row that ends at its state, and one separated by tabs. Both are rows the word split accepts,
# so whatever skips lines before the split must accept them too.
one "$HDR
   0: 0100007F:0BB8 00000000:0000 0A" "$HDR"
assert_eq "pw:a-row-that-ends-at-its-state-is-read" "3000:lo" "$PW_SET"
one "$HDR
$(printf '   0:\t0100007F:0BB8\t00000000:0000\t0A\t00000000:00000000')" "$HDR"
assert_eq "pw:a-tab-separated-row-is-read" "3000:lo" "$PW_SET"
# The caller's IFS: honoured neither in the split nor afterwards. The old loop word-split with
# whatever IFS it was handed, so a caller's `IFS=:` cut every row at its colons.
PW_OLD_IFS="$IFS"
IFS=:
one "$HDR
$(row 0 0100007F:0BB8 00000000:0000 0A)" "$HDR"
PW_IFS_AFTER="$IFS"; IFS="$PW_OLD_IFS"
assert_eq "pw:a-caller-ifs-does-not-reach-the-scan" "3000:lo" "$PW_SET"
assert_eq "pw:the-scan-leaves-the-caller-ifs-alone" ":" "$PW_IFS_AFTER"
# noglob: off after the scan if it was off before, and still on if the caller had set it.
one "$HDR" "$HDR"
case "$-" in *f*) fail "pw:the-scan-leaves-noglob-off" "set -f was still on after the scan returned" ;;
             *)   pass "pw:the-scan-leaves-noglob-off" ;; esac
set -f; one "$HDR" "$HDR"; PW_FLAGS="$-"; set +f
case "$PW_FLAGS" in *f*) pass "pw:the-scan-keeps-a-callers-noglob" ;;
                    *)   fail "pw:the-scan-keeps-a-callers-noglob" "the caller's set -f was turned off" ;; esac
# The locale: the scan runs under C, and hands the caller's setting back. A SENTINEL rather than
# whatever LC_ALL was, because every scan above has already run -- a scan that leaked C would
# have leaked it before this line, and "unchanged" would compare C with C. Measured: it did.
PW_LC_WAS="${LC_ALL+set}"; PW_LC_ORIG="${LC_ALL-}"
LC_ALL=POSIX; one "$HDR" "$HDR"; PW_LC_AFTER="${LC_ALL-unset}"
if [ -n "$PW_LC_WAS" ]; then LC_ALL="$PW_LC_ORIG"; else unset LC_ALL; fi
assert_eq "pw:the-scan-leaves-the-callers-locale-alone" "POSIX" "$PW_LC_AFTER"

# ─── garbage in: never a crash, never a bogus port ─────────────────────────────
BAD=''
feed() {                              # feed LABEL V4 V6
    local e p c
    PW_SET=''
    pw_scan_text "$1" "$2" 2>"$WORK/pw.err" || true
    [ -s "$WORK/pw.err" ] && BAD="${BAD:-$3 -> stderr: $(cat "$WORK/pw.err")}"
    for e in $PW_SET; do
        p="${e%%:*}"; c="${e#*:}"
        case "$p" in ''|*[!0-9]*) BAD="${BAD:-$3 -> non-decimal '$e'}"; continue ;; esac
        [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || BAD="${BAD:-$3 -> range '$e'}"
        # ASKED OF $c, not of a padded list (SC2194): a constant case subject is the shape that
        # reads as a forgotten `$`, and the alternation says the same thing about the same value.
        case "$c" in lo|any|v6lo|eth|loalt) ;; *) BAD="${BAD:-$3 -> class '$e'}" ;; esac
    done
}
feed "" "" "empty"
feed "$HDR" "$HDR" "header-only"
feed "not a proc file at all" "" "prose"
feed "$HDR
   0: ZZZZZZZZ:GGGG 00000000:0000 0A" "" "non-hex"
feed "$HDR
   0: 0100007F 00000000:0000 0A" "" "no-colon-in-address"
feed "$HDR
   0: 0100007F:0BB8" "" "truncated-row"
feed "$HDR
   0: 0100007F:0000 00000000:0000 0A" "" "port-zero"
feed "$HDR
   0: 0100007F:FFFFF 00000000:0000 0A" "" "port-overlong-hex"
feed "$(printf '%s\n   0: 0100007F:0BB8 00000000:0000 0A\r' "$HDR")" "" "carriage-returns"
feed "$HDR
   0: 0100007F:0BB8 00000000:0000 0a" "" "lowercase-state"
assert_eq "pw:garbage-never-yields-a-bad-port" "" "$BAD"


# ═══════════════════════════════════════════════════════════════════════════════
#  THE WRITEBACK: the argv the host sends in, and the file the container writes out
# ═══════════════════════════════════════════════════════════════════════════════
#
# These are the third and fourth parsers that take real input. The argv is host-constructed and
# therefore trusted-ish -- but "trusted-ish" is how the wrong thing gets written to a file three
# other readers depend on, so it is validated like anything else. The file is written by us and
# read by --show, by doctor over podman exec, and by shortlink before it prints a URL a student
# will click; a malformed one must be REPORTED, never silently half-read.

for fn in pw_publish_parse pw_state_parse pw_state_read; do
    command -v "$fn" >/dev/null 2>&1 || { fail "pw:$fn-exists" "$fn is not defined in files/cs193v-portwatch."; exit 1; }
    pass "pw:$fn-exists"
done

# EVERY FILE BELOW IS IN $WORK. pw_publish runs `mkdir -p "$PW_STATE_DIR"` before it writes
# $PW_STATE, so both are pointed here, or a run on a Mac would make /tmp/cs193v-volatile behind the
# scratch directory's back (#379).
# shellcheck disable=SC2034   # PW_STATE_DIR is read by the sourced cs193v-portwatch
PW_STATE_DIR="$WORK"; PW_STATE="$WORK/ports"

# What `--publish ARGS` writes, read back byte for byte. The real writer and the real read, so a
# case built on it is a file the system can produce rather than one a test typed in.
pw_written() {                        # pw_written ARGS... -> PW_FILE, or 1 if the writer refused
    PW_FILE=''
    rm -f "$PW_STATE"
    pw_main --publish "$@" 2>/dev/null && pw_state_read
}

# ─── argv in ───────────────────────────────────────────────────────────────────
pub_ok() {                            # pub_ok NAME EXPECT_UP ARGS...
    local name="$1" want="$2" rc; shift 2
    pw_publish_parse "$@" 2>/dev/null; rc=$?
    if [ "$rc" -eq 0 ] && [ "$PWP_UP" = "$want" ]; then
        pass "pw:publish:$name"
    else
        fail "pw:publish:$name" "rc=$rc up='${PWP_UP:-}' err='${PWP_ERR:-}'"
    fi
}
# EACH CASE NAMES ITS REASON, exactly, as the reader's do below (#404). Without it a case passed on
# whichever rejection fired first: with the no-colon check deleted, port-no-class stayed green on
# "unknown value '3000'".
pub_bad() {                           # pub_bad NAME WHY ARGS...
    local name="$1" why="$2"; shift 2
    if pw_publish_parse "$@" 2>/dev/null; then
        fail "pw:publish-rejects:$name" "accepted it; up='${PWP_UP:-}'"
    elif [ "$PWP_ERR" = "$why" ]; then
        pass "pw:publish-rejects:$name"
    else
        fail "pw:publish-rejects:$name" "rejected it, but for \"$PWP_ERR\" rather than \"$why\""
    fi
    PUB_BAD_RAN=$(( PUB_BAD_RAN + 1 ))
}
PUB_BAD_RAN=0

# ALL FOUR KEYS, EVERY TIME, because that is what the host sends (sup_publish): the floor, and an
# up= and a refused= even when they are empty. A publish missing one came from something else.
pub_ok "simple"    "3000:lo"          "state=healthy" "floor=1024" "up=3000:lo" "refused="
pub_ok "several"   "3000:lo 41573:lo" "state=healthy" "floor=1024" "up=3000:lo,41573:lo" "refused="
pub_ok "empty-up"  ""                 "state=healthy" "floor=1024" "up=" "refused="
pub_ok "with-all"  "3000:lo"          "state=healthy" "floor=1024" "up=3000:lo" "refused=8080:busy"
# A PORT IN BOTH LISTS IS LEGAL, because the host can publish one (#517), so neither end refuses it.
pub_ok "a-port-in-both-lists" "3000:lo" "state=healthy" "floor=1024" "up=3000:lo" "refused=3000:v6lo"

# PW_MAX OF EACH is the most the host can send: it forwards at most DYNPORTS_MAX ports, its gate
# refuses a frame of more records than that, and 10-static.sh holds the two caps equal. Built from
# PW_MAX rather than written out, so the cases follow the cap wherever it moves.
pw_nlist() {                          # pw_nlist N WORD -> PW_NLIST (comma-joined), PW_NLIST_SP
    local i=1
    PW_NLIST=''
    while [ "$i" -le "$1" ]; do
        PW_NLIST="$PW_NLIST,$(( 1000 + i )):$2"
        i=$(( i + 1 ))
    done
    PW_NLIST="${PW_NLIST#,}"; PW_NLIST_SP="${PW_NLIST//,/ }"
}
pw_nlist "$PW_MAX" lo
pub_ok "max-up"      "$PW_NLIST_SP"   "state=healthy" "floor=1024" "up=$PW_NLIST" "refused="
pw_nlist "$PW_MAX" busy
pub_ok "max-refused" ""               "state=healthy" "floor=1024" "up=" "refused=$PW_NLIST"

# bad-class and bad-reason offer each other's vocabulary: `busy` is a reason and `lo` a class
# (#410). A word in neither list stays refused by a check widened to accept both, so its case
# stays green whichever list the check used. The reader's two cases below do the same.
pub_bad "no-state"         "no state given"             "up=3000:lo"
pub_bad "unknown-state"    "unknown state: confused"    "state=confused" "up="
pub_bad "unknown-key"      "unknown key: colour"        "state=healthy" "colour=blue"
pub_bad "bare-word"        "not key=value: hello"       "state=healthy" "hello"
pub_bad "duplicate-key"    "duplicate up"               "state=healthy" "up=3000:lo" "up=5173:lo"
pub_bad "bad-class"        "unknown value: busy"        "state=healthy" "up=3000:busy"
pub_bad "bad-port"         "port out of range: 0"       "state=healthy" "up=0:lo"
pub_bad "octal-port"       "non-canonical port: 03000"  "state=healthy" "up=03000:lo"
pub_bad "port-no-class"    "no colon in entry: 3000"    "state=healthy" "up=3000"
pub_bad "bad-reason"       "unknown value: lo"          "state=healthy" "refused=8080:lo"
pub_bad "floor-not-a-port" "floor out of range: 0"      "state=healthy" "floor=0" "up="
pub_bad "floor-nondecimal" "non-decimal floor: x"       "state=healthy" "floor=x" "up="
# floor-octal is the canonical spelling pw_port added when the floor became one check for both
# ends (#406). The two duplicate cases drive checks the writer always had and nothing tested.
pub_bad "floor-octal"      "non-canonical floor: 01024" "state=healthy" "floor=01024" "up="
pub_bad "duplicate-state"  "duplicate state"            "state=healthy" "state=broken"
pub_bad "duplicate-floor"  "duplicate floor"            "state=healthy" "floor=1024" "floor=2048"
# The two control-character cases matter because the file is tab-separated and line-oriented: a
# value carrying either would inject a column or a whole record. What actually stops them is the
# VOCABULARY check -- `lo<TAB>` is not in the class list -- rather than any dedicated escaping
# pass. Verified by removing the vocabulary check, at which point both go red.
pub_bad "embedded-tab"     "unknown value: \$'lo\\t'"  "state=healthy" "up=3000:lo$(printf '\t')"
pub_bad "embedded-newline" "unknown value: \$'lo\\nup=9:lo'" \
                                                        "state=healthy" "up=$(printf '3000:lo\nup=9:lo')"
# WHAT THE HOST NEVER SENDS. A publish without one of the four keys, an up entry that is not `lo`
# (sup_publish writes every one as `$port:lo`), a port twice in one list, or more than PW_MAX.
pub_bad "no-floor"         "no floor given"             "state=healthy" "up=" "refused="
pub_bad "no-up-key"        "no up given"                "state=healthy" "floor=1024" "refused="
pub_bad "no-refused-key"   "no refused given"           "state=healthy" "floor=1024" "up="
pub_bad "up-not-lo"        "up entry not on lo: 3000:any" "state=healthy" "floor=1024" "up=3000:any" "refused="
pub_bad "duplicate-up-port" "duplicate up port: 3000"   "state=healthy" "floor=1024" "up=3000:lo,3000:lo" "refused="
# Two reasons for one port, so a duplicate check keyed on the whole entry would let it through.
pub_bad "duplicate-refused-port" "duplicate refused port: 8080" \
                                                        "state=healthy" "floor=1024" "up=" "refused=8080:busy,8080:v6lo"
pw_nlist "$(( PW_MAX + 1 ))" lo
pub_bad "too-many-up"      "more than $PW_MAX up entries" \
                                                        "state=healthy" "floor=1024" "up=$PW_NLIST" "refused="
pw_nlist "$(( PW_MAX + 1 ))" busy
pub_bad "too-many-refused" "more than $PW_MAX refused entries" \
                                                        "state=healthy" "floor=1024" "up=" "refused=$PW_NLIST"
# TWO WORDS THAT SIT SIDE BY SIDE IN A VOCABULARY, joined by a space. The check used to look for
# " $word " inside " $vocab ", which finds `busy v6lo` in the reasons, so the writer took it as one
# reason and rendered it as two lines its own reader refused. Each pair below is adjacent in its list.
pub_bad "joined-states"    "unknown state: master-unresponsive\\ broken" \
                                                        "state=master-unresponsive broken" "floor=1024" "up=" "refused="
pub_bad "joined-classes"   "unknown value: lo\\ any"     "state=healthy" "floor=1024" "up=3000:lo any" "refused="
pub_bad "joined-reasons"   "unknown value: busy\\ v6lo"  "state=healthy" "floor=1024" "up=" "refused=8080:busy v6lo"
# AN EMPTY ENTRY, at the end or in the middle. A list split on commas drops a trailing empty field,
# so `3000:lo,` once read as `3000:lo`: a spelling the host never sends, accepted.
pub_bad "trailing-comma"   "no colon in entry: ''"      "state=healthy" "floor=1024" "up=3000:lo," "refused="
pub_bad "doubled-comma"    "no colon in entry: ''"      "state=healthy" "floor=1024" "up=3000:lo,,5173:lo" "refused="

# A REFUSAL QUOTES WHAT IT REFUSED as the host's gate does (quoted() in cs193v-ui.sh): REASON:
# VALUE, the value through printf %q. doctor puts the reader's on a student's screen, so an escape
# must arrive as \E and not as a command to their terminal, and a \r, a tab and an ESC must stay
# three things -- a `?` for every unprintable byte made them one.
pub_bad "a-carriage-return-is-quoted" "unknown state: \$'healthy\\r'" \
                                                        $'state=healthy\r' "floor=1024" "up=" "refused="
pub_bad "an-escape-is-quoted" "unknown state: \$'hea\\Elthy'" \
                                                        $'state=hea\033lthy' "floor=1024" "up=" "refused="
assert_eq "pw:publish-every-rejection-ran" "32" "$PUB_BAD_RAN"
# A GLOB IS NOT EXPANDED in a split. With a file named `3000:lo` where the writer runs, `3000:l?`
# would become it, and an entry the host never sends would be taken.
PW_GLOB="$(cd "$WORK" && : > "3000:lo" && { pw_publish_parse state=healthy floor=1024 'up=3000:l?' refused=; printf '%s' "$PWP_ERR"; })"
rm -f "$WORK/3000:lo"
assert_eq "pw:publish-expands-no-glob" "unknown value: l\\?" "$PW_GLOB"
assert_eq "pw:publish-prints-the-quoted-reason" "cs193v-portwatch: unknown state: \$'hea\\Elthy'" \
          "$(pw_main --publish $'state=hea\033lthy' floor=1024 up= refused= 2>&1 >/dev/null)"
# CUT TO PW_VALUE_MAX BYTES, BEFORE IT IS QUOTED. What it quotes has no length of its own, and doctor
# gives the whole reason one row; cut after quoting, it could split an escape like \E and misreport
# the byte. The runs are built from PW_VALUE_MAX, so the cases follow the cap wherever it moves.
pw_run() {                            # pw_run N TEXT -> PW_RUN, TEXT N times
    PW_RUN="$(do_awk -v n="$1" -v t="$2" 'BEGIN { for (i = 0; i < n; i++) printf "%s", t }')"
}
pw_run "$PW_VALUE_MAX" x;   PW_XS="$PW_RUN"
pw_run "$PW_VALUE_MAX" '\\E'; PW_ES="$PW_RUN"
pw_publish_parse "state=$PW_XS" floor=1024 up= refused=
assert_eq "pw:publish-quotes-a-value-of-the-cap-whole" "unknown state: $PW_XS" "$PWP_ERR"
pw_publish_parse "state=${PW_XS}y" floor=1024 up= refused=
assert_eq "pw:publish-cuts-a-value-past-the-cap" \
          "unknown state: $PW_XS (the first $PW_VALUE_MAX of $(( PW_VALUE_MAX + 1 )) bytes)" "$PWP_ERR"
pw_run "$(( PW_VALUE_MAX + 8 ))" $'\033'
pw_publish_parse "state=$PW_RUN" floor=1024 up= refused=
assert_eq "pw:publish-cuts-before-it-quotes" \
          "unknown state: \$'$PW_ES' (the first $PW_VALUE_MAX of $(( PW_VALUE_MAX + 8 )) bytes)" "$PWP_ERR"
# BYTES, IN ANY LOCALE. Counted in a UTF-8 one, a cut keeps the whole é, and %q there writes it raw,
# a byte outside the ASCII the rest of doctor's row is. Skipped where no UTF-8 locale exists.
PW_UTF8=''
for l in C.UTF-8 en_US.UTF-8; do
    # shellcheck disable=SC2030,SC2031   # the subshell's locale is the point
    if ( LC_ALL="$l"; v=$'\303\251'; [ "${#v}" -eq 1 ] ) 2>/dev/null; then PW_UTF8="$l"; break; fi
done
if [ -n "$PW_UTF8" ]; then
    pw_run "$(( PW_VALUE_MAX - 1 ))" x
    assert_eq "pw:publish-quotes-bytes-in-$PW_UTF8" "unknown state: \$'caf\\303\\251'" \
              "$(LC_ALL="$PW_UTF8"; pw_publish_parse $'state=caf\303\251' floor=1024 up= refused=; printf '%s' "$PWP_ERR")"
    assert_eq "pw:publish-cuts-bytes-in-$PW_UTF8" \
              "unknown state: \$'$PW_RUN\\303' (the first $PW_VALUE_MAX of $(( PW_VALUE_MAX + 2 )) bytes)" \
              "$(LC_ALL="$PW_UTF8"; pw_publish_parse "state=$PW_RUN"$'\303\251b' floor=1024 up= refused=; printf '%s' "$PWP_ERR")"
else
    skip "pw:publish-quotes-bytes-in-a-utf-8-locale" "no C.UTF-8 or en_US.UTF-8 locale here"
fi

# ─── file out, and back in ─────────────────────────────────────────────────────
# ROUND TRIP. Whatever the writer emits, the reader must read back identically -- that is the
# only property that matters across the two, and it is the one a format change would break.
#
# THE PARSE ITSELF IS A CHECK (#392). The reader fills PWS_* a line at a time, so by the time it
# refuses a record it has set the fields before it, and their checks below pass on a refused file.
# So is the publish (#410): a writer that refuses an argument renders a short file the reader
# accepts, and the value checks below, failing alone, would blame the reader for what it left out.
#
# READ BACK WITH pw_state_read, NOT $(cat), which strips the trailing newline -- and a file without
# it is one the writer never wrote, so the reader refuses it.
if pw_written "state=healthy" "floor=1024" "up=3000:lo,41573:lo" "refused=8080:busy,9000:v6lo"; then
    pass "pw:roundtrip-publishes"
else
    fail "pw:roundtrip-publishes" "--publish refused the round trip's own arguments: ${PWP_ERR:-no reason given}"
fi
if pw_state_parse "$PW_FILE"; then
    pass "pw:roundtrip-parses"
else
    fail "pw:roundtrip-parses" "pw_state_parse returned $? on what --publish wrote: ${PWS_ERR:-no reason given}"
fi
assert_eq "pw:roundtrip-state"   "healthy"              "$PWS_STATE"
assert_eq "pw:roundtrip-floor"   "1024"                 "$PWS_FLOOR"
assert_eq "pw:roundtrip-up"      "3000:lo 41573:lo"     "$PWS_UP"
assert_eq "pw:roundtrip-refused" "8080:busy 9000:v6lo"  "$PWS_REFUSED"

# --state PRINTS EVERY BYTE, the trailing newline included, because doctor and shortlink read the
# file through it and a copy short of one byte is a different file. The literal first, so an empty
# file cannot pass the comparison by matching an empty copy.
PW_DISK="$(cat "$PW_STATE"; printf x)"; PW_DISK="${PW_DISK%x}"
assert_eq "pw:roundtrip-wrote-the-file" \
          "state${A_TAB}healthy
floor${A_TAB}1024
up${A_TAB}3000${A_TAB}lo
up${A_TAB}41573${A_TAB}lo
refused${A_TAB}8080${A_TAB}busy
refused${A_TAB}9000${A_TAB}v6lo
" "$PW_DISK"
PW_OUT="$(pw_main --state 2>/dev/null; printf x)"; PW_OUT="${PW_OUT%x}"
assert_eq "pw:state-prints-every-byte" "$PW_DISK" "$PW_OUT"

# ─── --state, against each kind of file it can find ────────────────────────────
# FOUR ANSWERS, and doctor and shortlink each act on which: 0 a file the writer wrote, 3 an empty
# one (a watcher has started and nothing is published yet), 4 none at all, 5 anything else.
st_case() {                           # st_case NAME RC STDERR -- --state on whatever $PW_STATE is now
    local rc out err
    pw_main --state >"$WORK/st.out" 2>"$WORK/st.err"; rc=$?
    out="$(cat "$WORK/st.out")"; err="$(cat "$WORK/st.err")"
    if [ "$rc" = "$2" ] && [ "$err" = "$3" ] && [ -z "$out" ]; then
        pass "pw:state:$1"
    else
        fail "pw:state:$1" "rc=$rc (wanted $2), stderr '$err' (wanted '$3'), ${#out} bytes on stdout"
    fi
}
rm -f "$PW_STATE"
st_case "no-file-is-4"           4 ""
: > "$PW_STATE"
st_case "an-empty-file-is-3"     3 ""
printf 'state\thealthy\n' > "$PW_STATE"
st_case "a-refused-file-is-5"    5 "cs193v-portwatch: line 2 differs from what --publish writes"
printf 'state\thealthy\nfloor\t1024' > "$PW_STATE"
st_case "no-final-newline-is-5"  5 "cs193v-portwatch: no newline at the end of line 2"
# A NUL IS INVISIBLE TO $(cat), which drops it -- silently on bash 3.2 -- and leaves a valid file.
printf 'state\thea\000lthy\nfloor\t1024\n' > "$PW_STATE"
st_case "a-nul-inside-is-5"      5 "cs193v-portwatch: NUL byte in the state file"
printf 'state\thealthy\nfloor\t1024\n\000' > "$PW_STATE"
st_case "a-nul-at-the-end-is-5"  5 "cs193v-portwatch: NUL byte in the state file"
# THE REASON QUOTES THE FILE, and doctor prints it on a student's screen, so an escape in the file
# arrives as \E rather than as a command to their terminal. And a file saved with CRLF endings says
# \r, which a `?` once said for every byte it hid.
printf 'state\thea\033lthy\nfloor\t1024\n' > "$PW_STATE"
st_case "an-escape-in-the-reason-is-quoted" 5 "cs193v-portwatch: unknown state: \$'hea\\Elthy'"
printf 'state\thealthy\r\nfloor\t1024\r\n' > "$PW_STATE"
st_case "crlf-endings-say-so" 5 "cs193v-portwatch: unknown state: \$'healthy\\r'"
# AND CUT BEFORE IT IS QUOTED, since what it quotes can be as long as the file.
pw_run "$(( PW_VALUE_MAX + 8 ))" $'\033'
printf 'state\t%s\nfloor\t1024\n' "$PW_RUN" > "$PW_STATE"
st_case "a-long-value-is-cut-before-quoting" 5 \
        "cs193v-portwatch: unknown state: \$'$PW_ES' (the first $PW_VALUE_MAX of $(( PW_VALUE_MAX + 8 )) bytes)"
rm -f "$PW_STATE"; mkdir "$PW_STATE"
st_case "a-directory-is-5"       5 "cs193v-portwatch: the state file is not a regular file"
rmdir "$PW_STATE"

# ─── the reader, against files it should refuse ────────────────────────────────
# EACH CASE NAMES ITS REASON, and the reader must give exactly that one (#391). A file is easily
# refused for something other than the defect it was written to carry -- with a value check
# deleted, the comparison at the end still refuses its file, as "line N differs" -- so "rejected"
# alone passes whatever the reader does about that defect. EXACT, not a prefix.
#
# A SHAPE HAS NO MESSAGE OF ITS OWN. A missing, repeated or unknown line is refused by the
# comparison, as the first line that is not what the writer writes; the checks that once named each
# one only named it, and refused nothing the comparison did not.
rd_bad() {                            # rd_bad NAME WHY TEXT
    if pw_state_parse "$3" 2>/dev/null; then
        fail "pw:state-rejects:$1" "accepted it"
    elif [ "$PWS_ERR" = "$2" ]; then
        pass "pw:state-rejects:$1"
    else
        fail "pw:state-rejects:$1" "rejected it, but for \"$PWS_ERR\" rather than \"$2\""
    fi
    RD_BAD_RAN=$(( RD_BAD_RAN + 1 ))
}
RD_BAD_RAN=0
rd_bad "empty"            "empty state file"            ""
rd_bad "no-state-line"    "line 1 differs from what --publish writes" "floor${A_TAB}1024"
rd_bad "unknown-key"      "line 2 differs from what --publish writes" "state${A_TAB}healthy
colour${A_TAB}blue"
rd_bad "bad-state"        "unknown state: sideways"     "state${A_TAB}sideways"
rd_bad "up-without-class" "up needs a port and a word"  "state${A_TAB}healthy
up${A_TAB}3000"
rd_bad "bad-class"        "unknown value: busy"         "state${A_TAB}healthy
up${A_TAB}3000${A_TAB}busy"
rd_bad "bad-port"         "port out of range: 0"        "state${A_TAB}healthy
up${A_TAB}0${A_TAB}lo"
rd_bad "space-separated"  "line 1 differs from what --publish writes" "state healthy"
rd_bad "floor-nondecimal" "non-decimal floor: x"        "state${A_TAB}healthy
floor${A_TAB}x"
# THE WRITER'S FLOOR RULE, read back in the writer's own words (#406), and its one-of-each rule
# (#411). Before #406 the reader took any run of digits for a floor, and before #411 a second state
# or floor line replaced the first.
rd_bad "floor-zero"       "floor out of range: 0"       "state${A_TAB}healthy
floor${A_TAB}0"
rd_bad "floor-too-high"   "floor out of range: 65536"   "state${A_TAB}healthy
floor${A_TAB}65536"
rd_bad "floor-overlong"   "over-long floor: 123456"     "state${A_TAB}healthy
floor${A_TAB}123456"
rd_bad "floor-octal"      "non-canonical floor: 01024"  "state${A_TAB}healthy
floor${A_TAB}01024"
rd_bad "duplicate-state"  "line 2 differs from what --publish writes" "state${A_TAB}healthy
state${A_TAB}broken"
rd_bad "duplicate-floor"  "line 3 differs from what --publish writes" "state${A_TAB}healthy
floor${A_TAB}1024
floor${A_TAB}2048"
# `lo` IS A CLASS, a word an `up` record may carry but a refusal may not, as `busy` in bad-class is
# a reason (#405, #410). A word in neither list would stay refused by a check widened to both.
rd_bad "bad-reason"       "unknown value: lo"           "state${A_TAB}healthy
refused${A_TAB}8080${A_TAB}lo"
# THE HOST'S RULES, read back: what the writer refuses to write, the reader refuses to read. Each
# file is otherwise exactly what the writer would produce, newline and all, so only the rule it
# breaks can refuse it.
PW_V="state${A_TAB}healthy
floor${A_TAB}1024
"
pw_nlines() {                         # pw_nlines N KEY WORD -> PW_NLINES, N records from port 1001
    local i=1
    PW_NLINES=''
    while [ "$i" -le "$1" ]; do
        PW_NLINES="$PW_NLINES$2$A_TAB$(( 1000 + i ))$A_TAB$3
"
        i=$(( i + 1 ))
    done
}
rd_bad "no-floor-line"    "line 2 differs from what --publish writes" "state${A_TAB}healthy
"
rd_bad "up-not-lo"        "up entry not on lo: 3000:any" "${PW_V}up${A_TAB}3000${A_TAB}any
"
rd_bad "duplicate-up-port" "duplicate up port: 3000"    "${PW_V}up${A_TAB}3000${A_TAB}lo
up${A_TAB}3000${A_TAB}lo
"
rd_bad "duplicate-refused-port" "duplicate refused port: 8080" "${PW_V}refused${A_TAB}8080${A_TAB}busy
refused${A_TAB}8080${A_TAB}v6lo
"
pw_nlines "$(( PW_MAX + 1 ))" up lo
rd_bad "too-many-up"      "more than $PW_MAX up entries" "$PW_V$PW_NLINES"
pw_nlines "$(( PW_MAX + 1 ))" refused busy
rd_bad "too-many-refused" "more than $PW_MAX refused entries" "$PW_V$PW_NLINES"
# A FILE NAMING EVERY PORT is refused at the cap rather than after all 65,535 lines, which shortlink
# would otherwise pay on every poll. The bound is a failure ceiling, not a delay a passing run pays:
# measured on bash 3.2, the stop answers in under 0.2s and the reader without it in about two
# minutes.
PW_ALL="$PW_V$(do_awk 'BEGIN { for (i = 1; i <= 65535; i++) printf "up\t%d\tlo\n", i }')"
pw_refuse_all() { pw_state_parse "$PW_ALL"; printf '%s' "$PWS_ERR" > "$WORK/every-port.why"; }
PW_ALL_SECS="$(elapsed pw_refuse_all)"
assert_eq "pw:state-rejects:every-port" "more than $PW_MAX up entries" "$(cat "$WORK/every-port.why" 2>/dev/null)"
record "pw:seconds-to-refuse-a-file-of-every-port" "$PW_ALL_SECS"
if faster_than 2 "$PW_ALL_SECS"; then
    pass "pw:a-file-of-every-port-is-refused-at-the-cap"
else
    fail "pw:a-file-of-every-port-is-refused-at-the-cap" "took ${PW_ALL_SECS}s; stopping at PW_MAX+1 lines takes hundredths"
fi
# AND ITS SHAPE: every value below is valid, and only the bytes around them are not what the writer
# writes. These are what the reader used to accept, because `IFS=<tab> read` treats a run of tabs as
# one and drops what is left over, and the loop took the lines in any order.
rd_bad "extra-field"      "line 1 differs from what --publish writes" "state${A_TAB}healthy${A_TAB}junk
floor${A_TAB}1024
"
rd_bad "doubled-tab"      "line 3 differs from what --publish writes" "${PW_V}up${A_TAB}${A_TAB}3000${A_TAB}lo
"
rd_bad "leading-tab"      "line 1 differs from what --publish writes" "${A_TAB}state${A_TAB}healthy
floor${A_TAB}1024
"
rd_bad "trailing-tab"     "line 3 differs from what --publish writes" "${PW_V}up${A_TAB}3000${A_TAB}lo${A_TAB}
"
rd_bad "blank-line"       "line 2 differs from what --publish writes" "state${A_TAB}healthy

floor${A_TAB}1024
"
rd_bad "floor-before-state" "line 1 differs from what --publish writes" "floor${A_TAB}1024
state${A_TAB}healthy
"
rd_bad "refused-before-up" "line 3 differs from what --publish writes" "${PW_V}refused${A_TAB}8080${A_TAB}busy
up${A_TAB}3000${A_TAB}lo
"
rd_bad "extra-final-newline" "line 3 differs from what --publish writes" "${PW_V}
"
rd_bad "no-final-newline" "no newline at the end of line 2" "state${A_TAB}healthy
floor${A_TAB}1024"
# THE WRITER'S JOINED WORDS, read back: one value made of two neighbours in its vocabulary. The
# reader shared the writer's substring check, so it took the state below whole, and the comparison
# could not see it, because the file re-renders to itself.
rd_bad "joined-states"    "unknown state: master-unresponsive\\ broken" "state${A_TAB}master-unresponsive broken
floor${A_TAB}1024
"
rd_bad "joined-reasons"   "unknown value: busy\\ v6lo"   "${PW_V}refused${A_TAB}8080${A_TAB}busy v6lo
"
# A COMMA IS ONE MORE BYTE OF A WORD, since the writer never writes one into the file. The reader
# once handed each line's value to the writer's list parser, which split it into entries, so one
# line could carry thousands of them; the cost section below times that.
rd_bad "comma-packed"     "unknown value: busy\\,9000:v6lo" "${PW_V}refused${A_TAB}8080${A_TAB}busy,9000:v6lo
"
assert_eq "pw:state-every-rejection-ran" "34" "$RD_BAD_RAN"

# ─── the reader, against files it must accept ──────────────────────────────────
# The edges of each rule, as the real writer writes them. A rule one step too strict refuses the
# host's own output, which the cases above cannot notice.
rd_ok() {                             # rd_ok NAME PUBLISH-ARGS...
    local name="$1"; shift
    if ! pw_written "$@"; then
        fail "pw:state-accepts:$name" "--publish refused the case's own arguments: ${PWP_ERR:-no reason given}"
    elif pw_state_parse "$PW_FILE"; then
        pass "pw:state-accepts:$name"
    else
        fail "pw:state-accepts:$name" "refused what --publish wrote: $PWS_ERR"
    fi
}
pw_nlist "$PW_MAX" lo
rd_ok "max-up"               "state=healthy" "floor=1024" "up=$PW_NLIST" "refused="
pw_nlist "$PW_MAX" busy
rd_ok "max-refused"          "state=healthy" "floor=1024" "up=" "refused=$PW_NLIST"
rd_ok "a-port-in-both-lists" "state=healthy" "floor=1024" "up=3000:lo" "refused=3000:v6lo"
rd_ok "floor-1"              "state=broken" "floor=1" "up=" "refused="
rd_ok "floor-65535"          "state=master-unresponsive" "floor=65535" "up=" "refused=21500:v6lo"

# ─── what a hostile size costs ─────────────────────────────────────────────────
# REFUSED IN WHAT A LEGAL INPUT COSTS, however large the input. Each pair below is one shape at
# 2000 entries and at 65,535, and each was quadratic or could become so:
#   * one refused line packed with comma-separated entries, which the reader handed to the
#     writer's list parser, peeling an entry at a time: 0.6 s at 2000 and 2.3 s at 4000, measured.
#   * one up= argument as long, which the writer peeled the same way and validated whole before
#     counting it: 1.8 s at 2000 and 30 s at 8000.
#   * a file of nothing but repeated state lines, one of repeated floor lines, and one of nothing
#     but junk. Each was refused near its top by a check that only named it; with those gone, the
#     parse must still stop there rather than read on to the end.
# FAIL FAST ON 2000, as the scan's cost check above does: a quadratic run is seconds there and
# minutes at 65,535. The ceilings are failure bounds, not delays a passing run pays.
pw_cost_input() {                     # pw_cost_input N SHAPE -> PW_CIN
    PW_CIN="$(do_awk -v n="$1" -v shape="$2" 'BEGIN {
        if (shape == "packed")  { printf "state\thealthy\nfloor\t1024\nrefused\t1\tbusy"
                                  for (i = 2; i <= n; i++) printf ",%d:busy", i; print "" }
        if (shape == "uplist")  { for (i = 1; i <= n; i++) printf "%s%d:lo", (i > 1 ? "," : ""), i }
        if (shape == "states")  { for (i = 1; i <= n; i++) print "state\thealthy" }
        if (shape == "floors")  { print "state\thealthy"; for (i = 1; i <= n; i++) print "floor\t1024" }
        if (shape == "junk")    { for (i = 1; i <= n; i++) print "x" }
    }'; printf x)"
    PW_CIN="${PW_CIN%x}"
}
pw_cost() {                           # pw_cost NAME SHAPE FN -- FN refuses $PW_CIN, cheaply at both sizes
    local s l rc
    pw_cost_input 2000 "$2"
    s="$(elapsed "$3")"
    record "pw:cost:$1:seconds-for-2000" "$s"
    if ! faster_than 0.25 "$s"; then
        fail "pw:cost:$1" "2000 entries took ${s}s, which is quadratic territory; not timing 65,535"
        return
    fi
    pw_cost_input 65535 "$2"
    l="$(elapsed "$3")"; rc=$?
    record "pw:cost:$1:seconds-for-65535" "$l"
    if [ "$rc" -ne 0 ] && faster_than 2 "$l"; then
        pass "pw:cost:$1"
    else
        fail "pw:cost:$1" "65,535 entries: rc=$rc (wanted a refusal) in ${l}s (wanted under 2)"
    fi
}
pw_cost_read()  { pw_state_parse "$PW_CIN"; }
pw_cost_write() { pw_publish_parse "state=healthy" "floor=1024" "up=$PW_CIN" "refused="; }
pw_cost "a-packed-line-is-refused-cheaply"       packed pw_cost_read
pw_cost "a-long-list-is-refused-cheaply"         uplist pw_cost_write
pw_cost "repeated-state-lines-are-refused-cheaply" states pw_cost_read
pw_cost "repeated-floor-lines-are-refused-cheaply" floors pw_cost_read
pw_cost "a-file-of-junk-is-refused-cheaply"      junk   pw_cost_read

# ─── every near miss of a real file, against a grammar that shares no code with the reader ─────
# THE TABLES ABOVE COULD NOT HAVE FOUND #406 OR #411. Each case was written for a check the reader
# already had, so a check nobody wrote had no case either, and the reader went on accepting bad
# floors, repeated lines, extra fields, runs of tabs and lines out of order with every case green.
#
# So this takes files the real writer wrote, applies every perturbation in a fixed list at every
# line, and asks whether the reader accepts exactly the ones a grammar accepts. The grammar is awk
# written here from the format, not from portwatch, so a reader that drifts from the format
# disagrees with it instead of agreeing with itself. ENUMERATED, NOT RANDOM: the same cases every
# run, so a failure names a case that reproduces.
PROP_NAMES=(); PROP_TEXTS=()
PROP_STATES='healthy master-unresponsive broken'
PROP_CLASSES='lo any v6lo eth loalt'
PROP_REASONS='busy v6lo loalt eth below-floor capped'
prop_add() { PROP_NAMES[${#PROP_NAMES[@]}]="$1"; PROP_TEXTS[${#PROP_TEXTS[@]}]="$2"; }
prop_lines() {                        # prop_lines NAME LINE... -> a case: each LINE and a newline
    local name="$1" t='' l; shift
    for l in "$@"; do t="$t$l
"; done
    prop_add "$name" "$t"
}
# These three read prop_base's L and G, by bash's dynamic scope.
prop_at() {                           # prop_at NAME I LINE -> line I of L replaced by LINE
    prop_lines "$1" ${L[@]+"${L[@]:0:$2}"} "$3" ${L[@]+"${L[@]:$2+1}"}
}
prop_fields() {                       # prop_fields NAME I -> line I of L replaced by G, tab-joined
    local j=1 t="${G[0]}"
    while [ "$j" -lt "${#G[@]}" ]; do t="$t$A_TAB${G[j]}"; j=$(( j + 1 )); done
    prop_at "$1" "$2" "$t"
}
prop_next() {                         # prop_next WORD LIST -> PROP_W, the word after WORD, cyclically
    local w first='' take=''
    for w in $2; do
        [ -n "$first" ] || first="$w"
        if [ -n "$take" ]; then PROP_W="$w"; return 0; fi
        [ "$w" = "$1" ] && take=1
    done
    PROP_W="$first"
}
prop_base() {                         # prop_base NAME TEXT -- TEXT itself, and every near miss of it
    local b="$1" text="$2" n i j nf line v new nums cands vocab other
    local -a L F G
    prop_add "$b" "$text"
    set -f
    IFS=$'\n'
    # shellcheck disable=SC2206   # splitting on newlines is the point, under set -f
    L=( ${text%$'\n'} )
    IFS=$' \t\n'
    # Every number in the file, so a replacement can collide with another port: that makes the
    # repeated ports, and the port in both lists, out of a file that had neither.
    nums=' '
    for line in ${L[@]+"${L[@]}"}; do
        IFS="$A_TAB"
        # shellcheck disable=SC2206   # and on tabs, the same way
        F=( $line )
        IFS=$' \t\n'
        for v in ${F[@]+"${F[@]}"}; do
            case "$v" in ''|*[!0-9]*) ;; *) case "$nums" in *" $v "*) ;; *) nums="$nums$v " ;; esac ;; esac
        done
    done
    cands="$nums"
    for v in 0 1 65535 65536; do case "$cands" in *" $v "*) ;; *) cands="$cands$v " ;; esac; done
    n=${#L[@]}
    i=0
    while [ "$i" -lt "$n" ]; do
        line="${L[i]}"
        prop_lines "$b/dup@$i"   "${L[@]:0:i+1}" "${L[@]:i}"
        prop_lines "$b/del@$i"   ${L[@]+"${L[@]:0:i}"} ${L[@]+"${L[@]:i+1}"}
        [ "$(( i + 1 ))" -lt "$n" ] && \
            prop_lines "$b/swap@$i" ${L[@]+"${L[@]:0:i}"} "${L[i+1]}" "$line" ${L[@]+"${L[@]:i+2}"}
        prop_lines "$b/blank@$i" ${L[@]+"${L[@]:0:i}"} "" "${L[@]:i}"
        prop_at "$b/lead-tab@$i"  "$i" "$A_TAB$line"
        prop_at "$b/trail-tab@$i" "$i" "$line$A_TAB"
        prop_at "$b/add-field@$i" "$i" "$line${A_TAB}lo"
        prop_at "$b/cr@$i"        "$i" "$line"$'\r'
        IFS="$A_TAB"
        # shellcheck disable=SC2206   # and on tabs, the same way
        F=( $line )
        IFS=$' \t\n'
        nf=${#F[@]}
        # each separator doubled, and each one a space
        j=1
        while [ "$j" -lt "$nf" ]; do
            G=( ${F[@]+"${F[@]}"} ); G[j]="$A_TAB${F[j]}"; prop_fields "$b/double-tab-$j@$i" "$i"
            G=( "${F[@]:0:j}" ); G[j-1]="${G[j-1]} ${F[j]}"
            [ "$(( j + 1 ))" -lt "$nf" ] && G=( ${G[@]+"${G[@]}"} "${F[@]:j+1}" )
            prop_fields "$b/space-$j@$i" "$i"
            j=$(( j + 1 ))
        done
        # the key, as each other key and in the wrong case
        for new in state floor up refused State; do
            [ "$new" = "${F[0]}" ] && continue
            G=( ${F[@]+"${F[@]}"} ); G[0]="$new"; prop_fields "$b/key-$new@$i" "$i"
        done
        # each value: a number gets a leading zero and every candidate; a word gets the next word
        # in its own list and a word from the other one
        j=1
        while [ "$j" -lt "$nf" ]; do
            v="${F[j]}"
            case "$v" in
                ''|*[!0-9]*)
                    case "${F[0]}" in
                        state)   vocab="$PROP_STATES";  other=lo ;;
                        up)      vocab="$PROP_CLASSES"; other=busy ;;
                        *)       vocab="$PROP_REASONS"; other=lo ;;
                    esac
                    prop_next "$v" "$vocab"
                    G=( ${F[@]+"${F[@]}"} ); G[j]="$PROP_W"; prop_fields "$b/next-word@$i" "$i"
                    G=( ${F[@]+"${F[@]}"} ); G[j]="$other";  prop_fields "$b/other-word@$i" "$i"
                    # the word and its neighbour as one value, which a substring check finds in
                    # the list; and a second entry packed in after a comma
                    G=( ${F[@]+"${F[@]}"} ); G[j]="$v $PROP_W"; prop_fields "$b/join-next-word@$i" "$i"
                    case "${F[0]}" in
                        up|refused) G=( ${F[@]+"${F[@]}"} ); G[j]="$v,1:$v"; prop_fields "$b/comma-pack@$i" "$i" ;;
                    esac ;;
                *)
                    G=( ${F[@]+"${F[@]}"} ); G[j]="0$v"; prop_fields "$b/lead-zero-$j@$i" "$i"
                    for new in $cands; do
                        [ "$new" = "$v" ] && continue
                        G=( ${F[@]+"${F[@]}"} ); G[j]="$new"; prop_fields "$b/num-$j-$new@$i" "$i"
                    done ;;
            esac
            j=$(( j + 1 ))
        done
        i=$(( i + 1 ))
    done
    set +f
    prop_add "$b/no-final-newline"    "${text%$'\n'}"
    prop_add "$b/extra-final-newline" "$text"$'\n'
}
prop_written() {                      # prop_written NAME PUBLISH-ARGS...
    local name="$1"; shift
    if pw_written "$@"; then
        prop_base "$name" "$PW_FILE"
    else
        fail "pw:prop:$name-is-written" "--publish refused the base's own arguments: ${PWP_ERR:-no reason given}"
    fi
}
prop_written B1 "state=healthy" "floor=1024" "up=" "refused="
prop_written B2 "state=healthy" "floor=1024" "up=3000:lo,41573:lo" "refused=8080:busy,9000:v6lo"
prop_written B3 "state=master-unresponsive" "floor=80" "up=" "refused=21500:v6lo,22:below-floor"
prop_written B4 "state=broken" "floor=65535" "up=1:lo" "refused=1:eth,65535:capped"
prop_add "empty-file" ""

# The reader's verdicts on JUDGE, one character per case, and its reason for each it refused: timed
# as a function because elapsed runs its command in a subshell, so both come back through files.
JUDGE=()
pw_judge() {
    local i=0 out='' why=''
    rm -f "$WORK/judge.verdicts" "$WORK/judge.why"
    while [ "$i" -lt "${#JUDGE[@]}" ]; do
        if pw_state_parse "${JUDGE[i]}"; then out="${out}1"; else out="${out}0"; why="$why$PWS_ERR"$'\036'; fi
        i=$(( i + 1 ))
    done
    printf '%s' "$out" > "$WORK/judge.verdicts"
    printf '%s' "$why" > "$WORK/judge.why"
}
JUDGE=( ${PROP_TEXTS[@]+"${PROP_TEXTS[@]}"} )
PROP_SECS="$(elapsed pw_judge)"
record "pw:prop:seconds-for-the-reader-to-judge-every-case" "$PROP_SECS"
PROP_READER="$(cat "$WORK/judge.verdicts" 2>/dev/null)"

# THE ORACLE. Each case is handed over after a \036, which no case contains, so every case is one awk
# record with its newlines intact, the empty one included. The grammar, from the format: a state line, a floor
# line, then up lines, then refused lines, each field separated by exactly one tab, ending in one
# newline; a port is a canonical 1-65535; an up word is lo; no port twice within a kind; at most
# PW_MAX of each. LC_ALL=C because the random cases further down carry any byte, and a grammar
# that reads them as characters would be judging different text from the reader.
#
# WHAT EACH GRAMMAR MEANS BY A PORT, A STATE AND A REASON is written once, here, from this file's
# own vocabularies, so this one and the publish grammar further down cannot drift apart. Neither
# shares a line with portwatch.
PROP_WORDS='
    BEGIN {
        split(STATES, W, " "); for (i in W) state[W[i]] = 1
        split(REASONS, W, " "); for (i in W) reason[W[i]] = 1
    }
    function isport(p) { return p ~ /^[1-9][0-9]*$/ && length(p) <= 5 && p + 0 <= 65535 }
    function isstate(s) { return s in state }
    function isreason(r) { return r in reason }
'
grammar_verdicts() {                  # grammar_verdicts GRAMMAR TEXT... -> a 0 or a 1 per TEXT
    local g="$1"; shift
    [ "$#" -gt 0 ] || return 0
    printf '%s\036' "$@" | LC_ALL=C do_awk -v MAX="$PW_MAX" -v STATES="$PROP_STATES" \
                                            -v REASONS="$PROP_REASONS" "$PROP_WORDS$g"
}
PROP_GRAMMAR='
    function legal(rec,   n, L, i, f, nf, nup, nref, su, sr, refusing) {
        if (rec == "" || substr(rec, length(rec), 1) != "\n") return 0
        n = split(rec, L, "\n")
        if (n < 3) return 0
        if (split(L[1], f, "\t") != 2 || f[1] != "state") return 0
        if (!isstate(f[2])) return 0
        if (split(L[2], f, "\t") != 2 || f[1] != "floor" || !isport(f[2])) return 0
        for (i = 3; i < n; i++) {
            if (split(L[i], f, "\t") != 3 || !isport(f[2])) return 0
            if (f[1] == "up") {
                if (refusing || f[3] != "lo" || (f[2] in su) || ++nup > MAX) return 0
                su[f[2]] = 1
            } else if (f[1] == "refused") {
                refusing = 1
                if (!isreason(f[3]) || (f[2] in sr) || ++nref > MAX) return 0
                sr[f[2]] = 1
            } else return 0
        }
        return 1
    }
    BEGIN { RS = "\036" }
    { printf "%d", legal($0) }
'
PROP_ORACLE="$(grammar_verdicts "$PROP_GRAMMAR" ${PROP_TEXTS[@]+"${PROP_TEXTS[@]}"})"

# THE BASES FIRST: a grammar or a reader that refuses the writer's own files would make every
# verdict after them meaningless, and agreeing about that would still pass the comparison below.
PROP_BASE_BAD=''
i=0
while [ "$i" -lt "${#PROP_NAMES[@]}" ]; do
    case "${PROP_NAMES[i]}" in
        B[0-9])
            [ "${PROP_READER:i:1}" = 1 ] || PROP_BASE_BAD="$PROP_BASE_BAD ${PROP_NAMES[i]}(reader)"
            [ "${PROP_ORACLE:i:1}" = 1 ] || PROP_BASE_BAD="$PROP_BASE_BAD ${PROP_NAMES[i]}(grammar)" ;;
    esac
    i=$(( i + 1 ))
done
assert_eq "pw:prop:the-writers-own-files-are-accepted" "" "$PROP_BASE_BAD"

# WHERE TWO SIDES' VERDICTS DIFFER: how many, and the first five, each with SHOW[i] quoted so every
# byte shows. N is how many verdicts each side must hold, so a side that stopped short cannot agree
# by having judged less.
SHOW=()
verdicts_agree() {                    # verdicts_agree NAME A B N WHAT -- A and B, N verdicts each, agree
    local i=0 q nd=0 diff=''
    if [ "$2" != "$3" ]; then
        while [ "$i" -lt "${#2}" ]; do
            if [ "${2:i:1}" != "${3:i:1}" ]; then
                nd=$(( nd + 1 ))
                if [ "$nd" -le 5 ]; then
                    printf -v q '%q' "${SHOW[i]}"
                    diff="$diff
  case $i: ${2:i:1} against ${3:i:1}: $q"
                fi
            fi
            i=$(( i + 1 ))
        done
    fi
    if [ "$nd" -eq 0 ] && [ "${#2}" -eq "$4" ] && [ "${#3}" -eq "$4" ]; then
        pass "$1"
    else
        fail "$1" "$nd of $4 disagree (${#2} and ${#3} verdicts; $5); the first:$diff"
    fi
}
SHOW=( ${PROP_NAMES[@]+"${PROP_NAMES[@]}"} )
verdicts_agree "pw:prop:the-reader-accepts-exactly-what-the-grammar-does" "$PROP_READER" "$PROP_ORACLE" \
               "${#PROP_NAMES[@]}" "the reader's, then the grammar's; 1 is accepted"
PROP_ACCEPTED="${PROP_ORACLE//0/}"; PROP_ACCEPTED="${#PROP_ACCEPTED}"
# LITERAL COUNTS, so a generator that quietly stops making cases, or a grammar that stops accepting
# any, cannot leave the comparison above agreeing about nothing.
assert_eq "pw:prop:cases-generated"          "400" "${#PROP_NAMES[@]}"
assert_eq "pw:prop:cases-the-grammar-allows" "67"  "$PROP_ACCEPTED"

# ─── random near misses, from a seed: bytes, and the format's own tokens ───────
# THE LIST ABOVE FINDS ONLY THE EDITS IT NAMES, and it named neither a space inside a value nor a
# comma: the writer and the reader both took `master-unresponsive broken` as one state, and the
# writer `busy v6lo` as one reason, with every case above green. So these are random, two ways:
#   * BYTES, any but NUL and the two separators below: inserted, replaced, deleted, repeated, or a
#     run of them inserted. These find what nobody thought to list.
#   * TOKENS: the separators, every vocabulary word alone and joined on by a space or a comma, and
#     the edge numbers, put anywhere, at the end of a field, or in place of one; and whole lines
#     repeated, dropped or swapped. These find what bytes almost never make: ` broken` is seven
#     particular bytes, about one chance in 256^7 per edit.
# Each case is a legal file, the writer's own or one built from random legal arguments, with one to
# three of those edits, judged by the reader and by the grammar above.
#
# SEEDED, so a failure reproduces: its message names the seed and the case. CS193V_FUZZ_SEED runs
# another seed and CS193V_FUZZ_CASES more cases, as 19-shortlink-fuzz.sh's seed does; the counts
# asserted at the end are for the defaults, and are only recorded for any other run.
#
# A THOUSAND OF EACH, because fewer missed what this section is for. Measured against the writer and
# reader before their joined-word fix, over seeds 1 to 10: 1000 cases caught them on all ten, 500 on
# seven and 300 on four. A thousand of each costs about three seconds here.
FZ_SEED="${CS193V_FUZZ_SEED:-20261012}"
FZ_CASES="${CS193V_FUZZ_CASES:-1000}"
for v in "$FZ_SEED" "$FZ_CASES"; do
    case "$v" in
        ''|*[!0-9]*) fail "pw:fuzz:the-seed-and-count-are-numbers" "CS193V_FUZZ_SEED='$FZ_SEED' CS193V_FUZZ_CASES='$FZ_CASES'"; exit 1 ;;
    esac
done
FZ_LCG=$(( 10#$FZ_SEED & 0x7FFFFFFF )); FZ_CASES=$(( 10#$FZ_CASES ))
# 17-portparse-fuzz.sh's generator, with its low bits dropped: in a power-of-two LCG the lowest bit
# only alternates, so `% 2` of the raw state would be a coin that always lands the other way.
fz_rand() {                           # fz_rand N -> FZ_R in [0,N), N from 1 to 32768
    FZ_LCG=$(( (FZ_LCG * 1103515245 + 12345) & 0x7FFFFFFF ))
    FZ_R=$(( (FZ_LCG >> 16) % $1 ))
}
# Every byte but NUL, which a bash string cannot hold (pw_state_read refuses it before any parse),
# and \036 and \037, which separate the cases and the arguments on their way to awk. Built once:
# printf -v, no fork.
FZ_BYTES=()
i=1
while [ "$i" -le 255 ]; do
    case "$i" in
        30|31) ;;
        *) printf -v v "\\$(( i / 64 ))$(( i / 8 % 8 ))$(( i % 8 ))"; FZ_BYTES[${#FZ_BYTES[@]}]="$v" ;;
    esac
    i=$(( i + 1 ))
done
FZ_TOKENS=( "$A_TAB" $'\n' ' ' ',' ':' '=' $'\r' state floor up refused 0 1 01024 1024 65535 65536 123456 )
for v in $PROP_STATES $PROP_CLASSES $PROP_REASONS; do
    FZ_TOKENS[${#FZ_TOKENS[@]}]="$v"; FZ_TOKENS[${#FZ_TOKENS[@]}]=" $v"; FZ_TOKENS[${#FZ_TOKENS[@]}]=",1:$v"
done
FZ_SEPS="$A_TAB"$'\n'
FZ_POOL=( 1 22 80 1023 1024 3000 5173 8080 21500 41573 65535 )
fz_port() {                           # -> FZ_P, a legal port: from the pool mostly, so lists collide
    fz_rand 4
    if [ "$FZ_R" -gt 0 ]; then
        fz_rand "${#FZ_POOL[@]}"; FZ_P="${FZ_POOL[FZ_R]}"
    else
        fz_rand 32768; FZ_P=$(( FZ_R * 2 )); fz_rand 2; FZ_P=$(( (FZ_P + FZ_R) % 65535 + 1 ))
    fi
}
# The vocabularies split once, since fz_word runs for nearly every entry of every case.
# shellcheck disable=SC2206   # the vocabularies are this file's own words, no globs
{ FZ_STATE_W=( $PROP_STATES ); FZ_REASON_W=( $PROP_REASONS ); FZ_ANY_W=( $PROP_CLASSES $PROP_REASONS ); }
fz_word() {                           # fz_word state|reason|any -> FZ_W, one of its words
    case "$1" in
        state)  fz_rand "${#FZ_STATE_W[@]}";  FZ_W="${FZ_STATE_W[FZ_R]}" ;;
        reason) fz_rand "${#FZ_REASON_W[@]}"; FZ_W="${FZ_REASON_W[FZ_R]}" ;;
        *)      fz_rand "${#FZ_ANY_W[@]}";    FZ_W="${FZ_ANY_W[FZ_R]}" ;;
    esac
}
pw_nlist "$PW_MAX" lo;   FZ_MAX_UP="$PW_NLIST"
pw_nlist "$PW_MAX" busy; FZ_MAX_REFUSED="$PW_NLIST"
fz_list() {                           # fz_list up|refused -> FZ_L, a legal list: 0-4 entries, or PW_MAX
    local n k=0 seen=' ' out=''
    fz_rand 50
    if [ "$FZ_R" -eq 0 ]; then
        if [ "$1" = up ]; then FZ_L="$FZ_MAX_UP"; else FZ_L="$FZ_MAX_REFUSED"; fi
        return 0
    fi
    fz_rand 5; n=$FZ_R
    while [ "$k" -lt "$n" ]; do
        fz_port
        case "$seen" in *" $FZ_P "*) continue ;; esac
        seen="$seen$FZ_P "
        if [ "$1" = up ]; then FZ_W=lo; else fz_word reason; fi
        out="$out,$FZ_P:$FZ_W"; k=$(( k + 1 ))
    done
    FZ_L="${out#,}"
}
fz_legal_args() {                     # -> FZ_ARGS, four arguments the host could send
    local s f u
    fz_word state; s="$FZ_W"
    fz_rand 3; if [ "$FZ_R" -eq 0 ]; then f=1024; else fz_port; f="$FZ_P"; fi
    fz_list up; u="$FZ_L"; fz_list refused
    FZ_ARGS=( "state=$s" "floor=$f" "up=$u" "refused=$FZ_L" )
}
fz_edit() {                           # fz_edit TEXT -> FZ_T, TEXT with one random edit
    local t="$1" n p q e e2 seg head rest l LC_ALL=C
    n=${#t}
    fz_rand 11
    case "$FZ_R" in
        0)  fz_rand $(( n + 1 )); p=$FZ_R; fz_rand "${#FZ_BYTES[@]}"; t="${t:0:p}${FZ_BYTES[FZ_R]}${t:p}" ;;
        1)  if [ "$n" -gt 0 ]; then fz_rand "$n"; p=$FZ_R; fz_rand "${#FZ_BYTES[@]}"; t="${t:0:p}${FZ_BYTES[FZ_R]}${t:p+1}"; fi ;;
        2)  if [ "$n" -gt 0 ]; then fz_rand "$n"; p=$FZ_R; t="${t:0:p}${t:p+1}"; fi ;;
        3)  if [ "$n" -gt 0 ]; then fz_rand "$n"; p=$FZ_R; t="${t:0:p+1}${t:p}"; fi ;;
        4)  fz_rand $(( n + 1 )); p=$FZ_R; fz_rand 8; q=$(( FZ_R + 1 )); seg=''
            while [ "$q" -gt 0 ]; do fz_rand "${#FZ_BYTES[@]}"; seg="$seg${FZ_BYTES[FZ_R]}"; q=$(( q - 1 )); done
            t="${t:0:p}$seg${t:p}" ;;
        5)  fz_rand $(( n + 1 )); p=$FZ_R; fz_rand "${#FZ_TOKENS[@]}"; t="${t:0:p}${FZ_TOKENS[FZ_R]}${t:p}" ;;
        6|9|10)  # at the end of a field, three times in eleven, as fz_args_edit weights its
            # value ends: the first tab or newline from a random place
            fz_rand $(( n + 1 )); p=$FZ_R; rest="${t:p}"; seg="${rest%%[$FZ_SEPS]*}"; p=$(( p + ${#seg} ))
            fz_rand "${#FZ_TOKENS[@]}"; t="${t:0:p}${FZ_TOKENS[FZ_R]}${t:p}" ;;
        7)  # in place of a field: from the separator before a random place to the one after it
            fz_rand $(( n + 1 )); p=$FZ_R; head="${t:0:p}"; rest="${t:p}"
            seg="${head%[$FZ_SEPS]*}"
            if [ "$seg" = "$head" ]; then q=0; else q=$(( ${#seg} + 1 )); fi
            seg="${rest%%[$FZ_SEPS]*}"; p=$(( p + ${#seg} ))
            fz_rand "${#FZ_TOKENS[@]}"; t="${t:0:q}${FZ_TOKENS[FZ_R]}${t:p}" ;;
        8)  # a whole line, from its start to just past its newline, repeated, dropped, or swapped
            fz_rand $(( n + 1 )); p=$FZ_R; head="${t:0:p}"
            seg="${head%$'\n'*}"
            if [ "$seg" = "$head" ]; then q=0; else q=$(( ${#seg} + 1 )); fi
            rest="${t:q}"; seg="${rest%%$'\n'*}"
            if [ "$seg" = "$rest" ]; then e=$n; else e=$(( q + ${#seg} + 1 )); fi
            l="${t:q:e-q}"
            fz_rand 3
            case "$FZ_R" in
                0) t="${t:0:e}$l${t:e}" ;;
                1) t="${t:0:q}${t:e}" ;;
                *) rest="${t:e}"; seg="${rest%%$'\n'*}"
                   if [ "$seg" = "$rest" ]; then e2=$n; else e2=$(( e + ${#seg} + 1 )); fi
                   t="${t:0:q}${t:e:e2-e}$l${t:e2}" ;;
            esac ;;
    esac
    FZ_T="$t"
}

# THE BASES: the four the writer wrote above, and forty more from random legal arguments, rendered
# by the writer's own two halves. A base the writer refuses means the generator is wrong, and every
# case built on it would be noise.
FZ_BASES=(); FZ_BAD_BASE=''
i=0
while [ "$i" -lt "${#PROP_NAMES[@]}" ]; do
    case "${PROP_NAMES[i]}" in B[0-9]) FZ_BASES[${#FZ_BASES[@]}]="${PROP_TEXTS[i]}" ;; esac
    i=$(( i + 1 ))
done
i=0
while [ "$i" -lt 40 ]; do
    fz_legal_args
    if pw_publish_parse ${FZ_ARGS[@]+"${FZ_ARGS[@]}"}; then
        pw_state_text "$PWP_STATE" "$PWP_FLOOR" "$PWP_UP" "$PWP_REFUSED"
        FZ_BASES[${#FZ_BASES[@]}]="$PW_RENDERED"
    else
        FZ_BAD_BASE="${FZ_BAD_BASE:-${FZ_ARGS[*]}: $PWP_ERR}"
    fi
    i=$(( i + 1 ))
done
assert_eq "pw:fuzz:the-legal-arguments-are-legal" "" "$FZ_BAD_BASE"

FZ_TEXTS=()
i=0
while [ "$i" -lt "$FZ_CASES" ]; do
    fz_rand "${#FZ_BASES[@]}"; FZ_T="${FZ_BASES[FZ_R]}"
    fz_rand 3; j=$(( FZ_R + 1 ))
    while [ "$j" -gt 0 ]; do fz_edit "$FZ_T"; j=$(( j - 1 )); done
    FZ_TEXTS[i]="$FZ_T"
    i=$(( i + 1 ))
done
JUDGE=( ${FZ_TEXTS[@]+"${FZ_TEXTS[@]}"} )
FZ_SECS="$(elapsed pw_judge)"
record "pw:fuzz:seconds-for-the-reader-to-judge-$FZ_CASES-random-files" "$FZ_SECS"
FZ_READER="$(cat "$WORK/judge.verdicts" 2>/dev/null)"
# Every reason either side gave, for the check that each is printable, after the round trip.
FZ_WHYS=()
IFS=$'\036' read -r -d '' -a FZ_WHYS < "$WORK/judge.why"
FZ_ORACLE="$(grammar_verdicts "$PROP_GRAMMAR" ${FZ_TEXTS[@]+"${FZ_TEXTS[@]}"})"
SHOW=( ${FZ_TEXTS[@]+"${FZ_TEXTS[@]}"} )
verdicts_agree "pw:fuzz:the-reader-accepts-exactly-what-the-grammar-does" "$FZ_READER" "$FZ_ORACLE" \
               "$FZ_CASES" "the reader's, then the grammar's, CS193V_FUZZ_SEED=$FZ_SEED; 1 is accepted"
FZ_ACCEPTED="${FZ_ORACLE//0/}"; FZ_ACCEPTED="${#FZ_ACCEPTED}"

# ─── random publishes, against a grammar of what the host sends ────────────────
# THE WRITER HAD NO GENERATED CASE AT ALL, only the table above, so nothing asked the question its
# joined-word bug failed: when --publish takes an argument, is what it writes a file the reader
# takes? Each case is the four arguments the host could send, with up to two random edits -- a
# token on a value, a byte edit anywhere in an argument, an argument dropped, repeated, added,
# swapped with another or replaced, an entry added to a list -- and three things must hold:
#   * the writer takes exactly what a grammar of the host's arguments takes, written in awk from
#     sup_publish's format: each of the four keys once, in any order; a known state; a canonical
#     floor; each list empty or comma-separated entries with no empty one, each a canonical port
#     not seen before in that list and a word (lo for up, a reason for refused), at most PW_MAX.
#   * whatever it takes, it renders to a file the reader and the file grammar both accept.
#   * whatever it refuses leaves the file alone. A sample, through the real --publish, since each
#     write it takes is two forks.
# A TOKEN ON THE END OF A VALUE IS THREE EDITS IN TEN, because that is where a value meets the
# separators the writer splits on. Measured on the writer before its joined-word fix: at one edit
# type in eight, the default seed found neither joined-word bug; at three in ten it finds both, and
# the trailing comma, and each of seeds 1 to 10 fails this property too.
fz_args_edit() {                      # one random edit to FZ_ARGS
    local n=${#FZ_ARGS[@]} k v
    fz_rand 10
    case "$FZ_R" in
        0|1|2) [ "$n" -gt 0 ] && { fz_rand "$n"; k=$FZ_R; fz_rand "${#FZ_TOKENS[@]}"; FZ_ARGS[k]="${FZ_ARGS[k]}${FZ_TOKENS[FZ_R]}"; } ;;
        3)  [ "$n" -gt 0 ] && { fz_rand "$n"; k=$FZ_R; fz_edit "${FZ_ARGS[k]}"; FZ_ARGS[k]="$FZ_T"; } ;;
        4)  [ "$n" -gt 0 ] && { fz_rand "$n"; k=$FZ_R; FZ_ARGS=( "${FZ_ARGS[@]:0:k}" "${FZ_ARGS[@]:k+1}" ); } ;;
        5)  [ "$n" -gt 0 ] && { fz_rand "$n"; FZ_ARGS[n]="${FZ_ARGS[FZ_R]}"; } ;;
        6)  fz_rand "${#FZ_TOKENS[@]}"; FZ_ARGS[n]="${FZ_TOKENS[FZ_R]}=1" ;;
        7)  [ "$n" -gt 1 ] && { fz_rand "$n"; k=$FZ_R; fz_rand "$n"; v="${FZ_ARGS[k]}"; FZ_ARGS[k]="${FZ_ARGS[FZ_R]}"; FZ_ARGS[FZ_R]="$v"; } ;;
        8)  [ "$n" -gt 0 ] && { fz_rand "$n"; k=$FZ_R; fz_rand "${#FZ_TOKENS[@]}"; FZ_ARGS[k]="${FZ_ARGS[k]%%=*}=${FZ_TOKENS[FZ_R]}"; } ;;
        *)  [ "$n" -gt 0 ] && {
                fz_rand "$n"; k=$FZ_R; fz_port; fz_word any
                case "${FZ_ARGS[k]}" in *=) v='' ;; *) v=',' ;; esac
                FZ_ARGS[k]="${FZ_ARGS[k]}$v$FZ_P:$FZ_W"
            } ;;
    esac
    return 0
}
FZ_WRITER=''; FZ_WROTE=(); FZ_PUBS=(); FZ_UNTOUCHED=''
i=0
while [ "$i" -lt "$FZ_CASES" ]; do
    fz_legal_args
    # One case in five left legal, so the writer is asked to take things as well as refuse them;
    # the rest get one edit or two.
    fz_rand 5
    if [ "$FZ_R" -eq 0 ]; then j=0; else fz_rand 2; j=$(( FZ_R + 1 )); fi
    while [ "$j" -gt 0 ]; do fz_args_edit; j=$(( j - 1 )); done
    # Each argument after a \037, so an empty last argument is still one, and none is one less.
    v=''; for a in ${FZ_ARGS[@]+"${FZ_ARGS[@]}"}; do v="$v"$'\037'"$a"; done
    FZ_PUBS[i]="$v"
    if pw_publish_parse ${FZ_ARGS[@]+"${FZ_ARGS[@]}"}; then
        FZ_WRITER="${FZ_WRITER}1"
        pw_state_text "$PWP_STATE" "$PWP_FLOOR" "$PWP_UP" "$PWP_REFUSED"
        FZ_WROTE[${#FZ_WROTE[@]}]="$PW_RENDERED"
    else
        FZ_WRITER="${FZ_WRITER}0"
        FZ_WHYS[${#FZ_WHYS[@]}]="$PWP_ERR"
    fi
    # The printed reason too, from these: what pw_publish writes, not only what it was handed.
    if [ "$i" -lt 40 ]; then
        printf 'untouched\n' > "$PW_STATE"
        if pw_main --publish ${FZ_ARGS[@]+"${FZ_ARGS[@]}"} 2>"$WORK/fz.err"; then
            v="$PW_RENDERED"; pw_state_read
            [ "$PW_FILE" = "$v" ] || FZ_UNTOUCHED="${FZ_UNTOUCHED:-case $i: took it, and wrote something else}"
        else
            pw_state_read
            [ "$PW_FILE" = $'untouched\n' ] || FZ_UNTOUCHED="${FZ_UNTOUCHED:-case $i: refused it, and changed the file}"
            v=''; IFS= read -r -d '' v < "$WORK/fz.err"
            FZ_WHYS[${#FZ_WHYS[@]}]="${v%$'\n'}"
        fi
    fi
    i=$(( i + 1 ))
done
FZ_ARGS_GRAMMAR='
    function list(v, up,   n, E, i, c, port, word, seen) {
        if (v == "") return 1
        n = split(v, E, ",")
        if (n > MAX) return 0
        for (i = 1; i <= n; i++) {
            c = index(E[i], ":")
            if (c == 0) return 0
            port = substr(E[i], 1, c - 1); word = substr(E[i], c + 1)
            if (!isport(port) || (port in seen)) return 0
            if (up ? word != "lo" : !isreason(word)) return 0
            seen[port] = 1
        }
        return 1
    }
    function legal(rec,   n, A, i, c, k, v, have) {
        n = split(rec, A, "\037")
        for (i = 2; i <= n; i++) {
            c = index(A[i], "=")
            if (c == 0) return 0
            k = substr(A[i], 1, c - 1); v = substr(A[i], c + 1)
            if (k in have) return 0
            have[k] = 1
            if (k == "state") { if (!isstate(v)) return 0 }
            else if (k == "floor") { if (!isport(v)) return 0 }
            else if (k == "up") { if (!list(v, 1)) return 0 }
            else if (k == "refused") { if (!list(v, 0)) return 0 }
            else return 0
        }
        return ("state" in have) && ("floor" in have) && ("up" in have) && ("refused" in have)
    }
    BEGIN { RS = "\036" }
    { printf "%d", legal($0) }
'
FZ_ARGS_ORACLE="$(grammar_verdicts "$FZ_ARGS_GRAMMAR" ${FZ_PUBS[@]+"${FZ_PUBS[@]}"})"
SHOW=( ${FZ_PUBS[@]+"${FZ_PUBS[@]}"} )
verdicts_agree "pw:fuzz:the-writer-accepts-exactly-what-the-host-sends" "$FZ_WRITER" "$FZ_ARGS_ORACLE" \
               "$FZ_CASES" "the writer's, then the grammar's, CS193V_FUZZ_SEED=$FZ_SEED; arguments after each \\037"
assert_eq "pw:fuzz:a-refused-publish-leaves-the-file-alone" "" "$FZ_UNTOUCHED"

# Every file the writer took: the reader takes it, and so does the file grammar.
FZ_WROTE_BAD=''
for t in ${FZ_WROTE[@]+"${FZ_WROTE[@]}"}; do
    pw_state_parse "$t" || { printf -v v '%q' "$t"; FZ_WROTE_BAD="${FZ_WROTE_BAD:-$v: $PWS_ERR}"; }
done
assert_eq "pw:fuzz:every-file-the-writer-takes-the-reader-takes" "" "$FZ_WROTE_BAD"
FZ_WROTE_ORACLE="$(grammar_verdicts "$PROP_GRAMMAR" ${FZ_WROTE[@]+"${FZ_WROTE[@]}"})"
assert_eq "pw:fuzz:every-file-the-writer-takes-the-grammar-takes" "${FZ_WROTE_ORACLE//0/}" "$FZ_WROTE_ORACLE"
FZ_PUB_ACCEPTED="${FZ_ARGS_ORACLE//0/}"; FZ_PUB_ACCEPTED="${#FZ_PUB_ACCEPTED}"

# ─── the round trip, from the reader's side ────────────────────────────────────
# EVERY FILE THE READER ACCEPTS, here or above, is one the writer would write from what the reader
# read out of it, byte for byte. A reader looser than the writer about some value fails this even
# where both grammars are silent on it.
FZ_TRIP_BAD=''; FZ_TRIPS=0; FZ_TOOK=()
i=0
while [ "$i" -lt "${#PROP_TEXTS[@]}" ]; do [ "${PROP_READER:i:1}" = 1 ] && FZ_TOOK[${#FZ_TOOK[@]}]="${PROP_TEXTS[i]}"; i=$(( i + 1 )); done
i=0
while [ "$i" -lt "${#FZ_TEXTS[@]}" ];   do [ "${FZ_READER:i:1}" = 1 ]   && FZ_TOOK[${#FZ_TOOK[@]}]="${FZ_TEXTS[i]}";   i=$(( i + 1 )); done
for t in ${FZ_TOOK[@]+"${FZ_TOOK[@]}"}; do
    pw_state_parse "$t" || { printf -v v '%q' "$t"; FZ_TRIP_BAD="${FZ_TRIP_BAD:-$v: refused on a second reading}"; continue; }
    FZ_TRIPS=$(( FZ_TRIPS + 1 ))
    if ! pw_publish_parse "state=$PWS_STATE" "floor=$PWS_FLOOR" "up=${PWS_UP// /,}" "refused=${PWS_REFUSED// /,}"; then
        printf -v v '%q' "$t"; FZ_TRIP_BAD="${FZ_TRIP_BAD:-$v: the writer refused what the reader read, $PWP_ERR}"
        continue
    fi
    pw_state_text "$PWP_STATE" "$PWP_FLOOR" "$PWP_UP" "$PWP_REFUSED"
    [ "$PW_RENDERED" = "$t" ] || { printf -v v '%q' "$t"; FZ_TRIP_BAD="${FZ_TRIP_BAD:-$v: the writer wrote something else}"; }
done
assert_eq "pw:fuzz:every-file-the-reader-takes-the-writer-writes" "" "$FZ_TRIP_BAD"

# ─── every reason, printable ───────────────────────────────────────────────────
# EVERY REASON EITHER SIDE GAVE IS PRINTABLE ASCII, whatever bytes its case carried. A value reaches
# a reason only through pw_refuse, so a message that skipped it would put the raw byte on doctor's
# row; the random cases carry every byte but three, and reach every message that names a value. And
# some reason must have had a byte to quote, or this held over reasons with nothing in them to quote.
# Counted as the reasons holding a $'...', which %q writes only to quote a byte: it escapes a $ or a
# ' that the value carried. So the count is literal for the defaults, as the counts below are, since
# a reason that never went through %q can carry the two characters too.
fz_unprintable() {                    # fz_unprintable REASON... -> FZ_BADWHY, the first not printable; FZ_QUOTED
    local w LC_ALL=C
    FZ_BADWHY=''; FZ_QUOTED=0
    for w in "$@"; do
        case "$w" in
            *[![:print:]]*) [ -n "$FZ_BADWHY" ] || printf -v FZ_BADWHY '%q' "$w" ;;
            *"\$'"*)        FZ_QUOTED=$(( FZ_QUOTED + 1 )) ;;
        esac
    done
}
fz_unprintable ${FZ_WHYS[@]+"${FZ_WHYS[@]}"}
record "pw:fuzz:reasons" "${#FZ_WHYS[@]} reasons, $FZ_QUOTED of them quoting a byte"
assert_eq "pw:fuzz:every-reason-is-printable-ascii" "" "$FZ_BADWHY"
if [ -z "${CS193V_FUZZ_SEED:-}" ] && [ -z "${CS193V_FUZZ_CASES:-}" ]; then
    assert_eq "pw:fuzz:reasons-that-quoted-a-byte" "183" "$FZ_QUOTED"
elif [ "$FZ_QUOTED" -gt 0 ]; then
    pass "pw:fuzz:some-reason-had-a-byte-to-quote"
else
    fail "pw:fuzz:some-reason-had-a-byte-to-quote" "none of the ${#FZ_WHYS[@]} reasons quoted one with \$'...'"
fi

# LITERAL COUNTS for the default seed and count, as the enumeration's: a generator that stopped
# making legal cases, or a grammar that stopped taking any, would leave every comparison above
# agreeing about nothing.
record "pw:fuzz:counts" "seed $FZ_SEED, $FZ_CASES of each: $FZ_ACCEPTED files and $FZ_PUB_ACCEPTED publishes legal, $FZ_TRIPS round trips"
if [ -z "${CS193V_FUZZ_SEED:-}" ] && [ -z "${CS193V_FUZZ_CASES:-}" ]; then
    assert_eq "pw:fuzz:random-files-the-grammar-allows"     "18"  "$FZ_ACCEPTED"
    assert_eq "pw:fuzz:random-publishes-the-grammar-allows" "260" "$FZ_PUB_ACCEPTED"
fi

# ─── what --show says when the tunnel itself has gone  (#338) ──────────────────
# Once the ssh master's control socket has gone (#338), or a forward through it has timed out
# (#266), the supervisor publishes master-unresponsive with nothing up. --show is what a student
# reads, and what agent-notes.md sends a coding agent to, so it has to say what happened and what
# to do -- not print the state's name and leave them to guess. The v6lo refusal is still listed:
# that advice is as true without a tunnel as with one.
printf 'state\tmaster-unresponsive\nfloor\t1024\nrefused\t21500\tv6lo\n' > "$PW_STATE"
PW_SHOWN="$(pw_show)"
assert_contains "pw:show-says-the-tunnel-has-stopped" "The tunnel to your own computer has stopped" "$PW_SHOWN"
assert_contains "pw:show-says-how-to-bring-it-back" "run: cs193v --reset-tunnel" "$PW_SHOWN"
assert_contains "pw:show-says-nothing-is-reachable" "Nothing of yours is reachable" "$PW_SHOWN"
assert_contains "pw:show-still-explains-a-refusal" "21500" "$PW_SHOWN"
# A FILE THE READER REFUSES is reported, never shown in part. An empty or a missing one is a tunnel
# that has not said anything yet.
printf 'state\thealthy\n' > "$PW_STATE"
PW_SHOWN="$(pw_show)"; PW_SHOW_RC=$?
assert_contains "pw:show-says-a-refused-file-is-unreadable" "unreadable (line 2 differs from what --publish writes)" "$PW_SHOWN"
assert_eq       "pw:show-fails-on-a-refused-file" "1" "$PW_SHOW_RC"
: > "$PW_STATE"
assert_contains "pw:show-has-nothing-yet-for-an-empty-file" "No forwarding information yet" "$(pw_show)"
rm -f "$PW_STATE"
assert_contains "pw:show-has-nothing-yet-without-a-file" "No forwarding information yet" "$(pw_show)"
rm -rf "$WORK"

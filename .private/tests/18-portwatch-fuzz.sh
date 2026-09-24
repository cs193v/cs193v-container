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

# Read by cs193v-portwatch:453, three lines below, which is a `.` shellcheck does not follow
# without -x -- and -x here would resolve the source and hide every finding this file has.
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
    pw_scan_text "$1" "$2" 2>/tmp/pw.err || true
    [ -s /tmp/pw.err ] && BAD="${BAD:-$3 -> stderr: $(cat /tmp/pw.err)}"
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
rm -f /tmp/pw.err


# ═══════════════════════════════════════════════════════════════════════════════
#  THE WRITEBACK: the argv the host sends in, and the file the container writes out
# ═══════════════════════════════════════════════════════════════════════════════
#
# These are the third and fourth parsers that take real input. The argv is host-constructed and
# therefore trusted-ish -- but "trusted-ish" is how the wrong thing gets written to a file three
# other readers depend on, so it is validated like anything else. The file is written by us and
# read by --show, by doctor over podman exec, and by shortlink before it prints a URL a student
# will click; a malformed one must be REPORTED, never silently half-read.

for fn in pw_publish_parse pw_state_parse; do
    command -v "$fn" >/dev/null 2>&1 || { fail "pw:$fn-exists" "$fn is not defined in files/cs193v-portwatch."; exit 1; }
    pass "pw:$fn-exists"
done

# ─── argv in ───────────────────────────────────────────────────────────────────
pub_ok() {                            # pub_ok NAME EXPECT_UP ARGS...
    local name="$1" want="$2"; shift 2
    if pw_publish_parse "$@" 2>/dev/null && [ "$PWP_UP" = "$want" ]; then
        pass "pw:publish:$name"
    else
        fail "pw:publish:$name" "rc=$? up='${PWP_UP:-}' err='${PWP_ERR:-}'"
    fi
}
pub_bad() {                           # pub_bad NAME ARGS...
    local name="$1"; shift
    if pw_publish_parse "$@" 2>/dev/null; then
        fail "pw:publish-rejects:$name" "accepted it; up='${PWP_UP:-}'"
    else
        [ -n "${PWP_ERR:-}" ] && pass "pw:publish-rejects:$name" \
                              || fail "pw:publish-rejects:$name" "rejected but set no reason"
    fi
    PUB_BAD_RAN=$(( PUB_BAD_RAN + 1 ))
}
PUB_BAD_RAN=0

pub_ok "simple"    "3000:lo"          "state=healthy" "up=3000:lo"
pub_ok "several"   "3000:lo 41573:any" "state=healthy" "up=3000:lo,41573:any"
pub_ok "empty-up"  ""                 "state=healthy" "up="
pub_ok "no-up-key" ""                 "state=healthy"
pub_ok "with-all"  "3000:lo"          "state=healthy" "floor=1024" "up=3000:lo" "refused=8080:busy"

pub_bad "no-state"          "up=3000:lo"
pub_bad "unknown-state"     "state=confused" "up="
pub_bad "unknown-key"       "state=healthy" "colour=blue"
pub_bad "bare-word"         "state=healthy" "hello"
pub_bad "duplicate-key"     "state=healthy" "up=3000:lo" "up=5173:lo"
pub_bad "bad-class"         "state=healthy" "up=3000:wat"
pub_bad "bad-port"          "state=healthy" "up=0:lo"
pub_bad "octal-port"        "state=healthy" "up=03000:lo"
pub_bad "port-no-class"     "state=healthy" "up=3000"
pub_bad "bad-reason"        "state=healthy" "refused=8080:whatever"
pub_bad "floor-not-a-port"  "state=healthy" "floor=0" "up="
pub_bad "floor-nondecimal"  "state=healthy" "floor=x" "up="
pub_bad "embedded-tab"      "state=healthy" "up=3000:lo$(printf '\t')"
pub_bad "embedded-newline"  "state=healthy" "up=$(printf '3000:lo\nup=9:lo')"
assert_eq "pw:publish-every-rejection-ran" "14" "$PUB_BAD_RAN"

# The two control-character cases matter because the file below is tab-separated and
# line-oriented: a value carrying either would inject a column or a whole record. What actually
# stops them is the VOCABULARY check -- `lo<TAB>` is not in the class list -- rather than any
# dedicated escaping pass. Verified by removing the vocabulary check, at which point
# publish-rejects:embedded-tab is one of the four that go red.

# ─── file out, and back in ─────────────────────────────────────────────────────
# ROUND TRIP. Whatever the writer emits, the reader must read back identically -- that is the
# only property that matters across the two, and it is the one a format change would break.
pw_publish_parse "state=healthy" "floor=1024" "up=3000:lo,41573:any" "refused=8080:busy,9000:v6lo"
pw_state_render > /tmp/pwstate.txt
pw_state_parse "$(cat /tmp/pwstate.txt)"
assert_eq "pw:roundtrip-state"   "healthy"              "$PWS_STATE"
assert_eq "pw:roundtrip-floor"   "1024"                 "$PWS_FLOOR"
assert_eq "pw:roundtrip-up"      "3000:lo 41573:any"    "$PWS_UP"
assert_eq "pw:roundtrip-refused" "8080:busy 9000:v6lo"  "$PWS_REFUSED"

# ─── the reader, against files it should refuse ────────────────────────────────
rd_bad() {                            # rd_bad NAME TEXT
    if pw_state_parse "$2" 2>/dev/null; then
        fail "pw:state-rejects:$1" "accepted it"
    else
        pass "pw:state-rejects:$1"
    fi
    RD_BAD_RAN=$(( RD_BAD_RAN + 1 ))
}
RD_BAD_RAN=0
rd_bad "empty"            ""
rd_bad "no-state-line"    "floor$(printf '\t')1024"
rd_bad "unknown-key"      "state${T:=$(printf '\t')}healthy
colour${T}blue"
rd_bad "bad-state"        "state${T}sideways"
rd_bad "up-without-class" "state${T}healthy
up${T}3000"
rd_bad "bad-class"        "state${T}healthy
up${T}3000${T}wat"
rd_bad "bad-port"         "state${T}healthy
up${T}0${T}lo"
rd_bad "space-separated"  "state healthy"
assert_eq "pw:state-every-rejection-ran" "8" "$RD_BAD_RAN"

# ─── what --show says when the tunnel itself has gone  (#338) ──────────────────
# Once the ssh master's control socket has gone, the supervisor publishes master-unresponsive with
# nothing up. --show is what a student reads, and what agent-notes.md sends a coding agent to, so
# it has to say what happened and what to do -- not print the state's name and leave them to
# guess. The v6lo refusal is still listed: that advice is as true without a tunnel as with one.
PW_STATE_WAS="$PW_STATE"; PW_STATE=/tmp/pwstate.txt
printf 'state\tmaster-unresponsive\nfloor\t1024\nrefused\t21500\tv6lo\n' > "$PW_STATE"
PW_SHOWN="$(pw_show)"
assert_contains "pw:show-says-the-tunnel-has-stopped" "The tunnel to your own computer has stopped" "$PW_SHOWN"
assert_contains "pw:show-says-how-to-bring-it-back" "run: cs193v --reset-tunnel" "$PW_SHOWN"
assert_contains "pw:show-says-nothing-is-reachable" "Nothing of yours is reachable" "$PW_SHOWN"
assert_contains "pw:show-still-explains-a-refusal" "21500" "$PW_SHOWN"
PW_STATE="$PW_STATE_WAS"
rm -f /tmp/pwstate.txt

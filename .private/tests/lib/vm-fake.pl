#!/usr/bin/env perl
#
# A stand-in for krunkit (vfkit on Intel): the long-lived VM process that `podman machine start`
# leaves running after it exits (#495). podman-fake's `machine start` launches it.
#
#   perl vm-fake.pl SHIM
#
# WHAT IT MODELS IS WHAT IT INHERITS, and nothing else. podman-fake launches it the way podman
# launches the real one -- a plain fork+exec, stdio on /dev/null, inherited fds passed straight
# through, and Go's signal rule applied first (see podman-fake's `machine start` arm) -- so the
# process group, session, controlling terminal, signal dispositions and open fds this ends up
# with are exactly what the caller's way of running `podman machine start` would hand the real
# VM. It installs NO handlers, because krunkit has none: a signal that is not ignored when it
# arrives ends this process, the way it ends a real guest (measured 2026-10-12, issue #495).
#
# IT SAYS WHAT IT INHERITED, FIRST, before it opens anything of its own:
#
#   $SHIM/vm.snapshot   `pid=N HUP=IGNORE INT=DEFAULT QUIT=DEFAULT TERM=DEFAULT fds=5,9`
#                       one line; fds lists which of 3..255 were open when it started
#   $SHIM/vm.pid        its pid, for `machine stop`, the tests and shim_kill_vms
#
# The snapshot is written to a temporary name and renamed, so a reader that sees the file sees
# all of it.
#
# IT ENDS ITSELF, because a process built to outlive its parent must not outlive the run that
# made it (#495 review, R4). Once its parent has gone it is reparented to pid 1 in a process
# group of its own, where run-tests.sh's group TERM and lane_outsiders cannot see it. So it exits
# when $SHIM is removed -- which shim_cleanup does -- or after CS193V_FAKE_VM_SECS seconds
# (default 300), whichever comes first. Its ONE-SECOND POLL is this process's own lifetime, not a
# wait for anything: there is no event to wait on when the event is "a directory went away".
#
# perl RATHER THAN sh, for the reason podman-fake records at the launch: a shell cannot see, let
# alone reset, a disposition that was ignored when it started, and dispositions are the point.

use strict;
use warnings;
use POSIX qw(:signal_h);

my $shim = shift @ARGV or die "usage: vm-fake SHIM\n";

# BEFORE ANYTHING ELSE IS OPENED: which fds above 2 did we inherit? POSIX::dup succeeds only on an
# open fd. 3..255 and not just the 3..9 a script can name, because the leak this was built to see
# arrived on fd 13: bash 3.2's saved copy of a fd the helper had "closed" (#495). Measured: perl
# itself holds nothing in that range while running a script file.
my @fds = grep { my $d = POSIX::dup($_); defined $d and POSIX::close($d), 1 } 3 .. 255;

my @disp;
for my $n (qw(HUP INT QUIT TERM)) {
    my $old = POSIX::SigAction->new;
    my $num = eval "POSIX::SIG$n()";
    sigaction($num, undef, $old) or die "sigaction $n: $!\n";
    my $h = $old->{HANDLER};
    push @disp, sprintf '%s=%s', $n, (defined $h && $h eq 'IGNORE') ? 'IGNORE' : 'DEFAULT';
}

sub put {
    my ($name, $text) = @_;
    my $tmp = "$shim/$name.tmp.$$";
    open(my $fh, '>', $tmp) or return;
    print $fh $text;
    close $fh;
    rename $tmp, "$shim/$name";
}
put('vm.snapshot', sprintf "pid=%d %s fds=%s\n", $$, join(' ', @disp), join(',', @fds));
put('vm.pid', "$$\n");

my $end = time + ($ENV{CS193V_FAKE_VM_SECS} || 300);
while (-d $shim && time < $end) {
    sleep 1;
}
exit 0;

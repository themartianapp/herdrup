#!/usr/bin/env python3
"""The subset of GNU `timeout` that Tools/ci/ui-shard.sh uses, for a Mac without coreutils.

    timeout.py [--signal=NAME] [--kill-after=DURATION] DURATION COMMAND [ARG...]

macOS ships no `timeout`, and macserve's job PATH has no Homebrew `gtimeout`. Like GNU
timeout: DURATION is a number with an optional s, m or h suffix; when it runs out the
command gets NAME (default TERM), then KILL after --kill-after if it is still running;
the exit status is 124 when the time ran out, else the command's own status (128 + N
for a command killed by signal N).

THE WHOLE PROCESS GROUP, as GNU timeout signals it. The command runs in a session of its
own, and the signal and the KILL go to that group: a descendant such as simctl under a
timed `bash -c` would otherwise outlive the deadline and hold the pipe of the round's
`| tee` open (review of #663, F1). With --kill-after, everything still in the group when
the grace runs out is killed; without it, as with GNU timeout, only the command itself
is waited for.

A SIGNAL SENT TO timeout.py GOES TO THE COMMAND'S GROUP, as GNU timeout forwards INT, TERM
and HUP: ui-shard.sh stops a round whose simulator stopped answering accessibility by
sending SIGINT to the timeout process it started in the background, and without this the
command, in a session of its own, would run on. The group then gets the same grace and
KILL as after a time-out, and the exit status is the command's own. The handlers are
installed before the command starts, so a timeout.py started in the background of a
script (where INT is ignored) still takes INT, and the command starts with INT at its
default instead of inheriting the ignore.
"""
import os
import signal
import subprocess
import sys
import time

FORWARDED = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


class Forwarded(Exception):
    """Raised once, by the first forwarded signal, to end the wait for the command."""


def seconds(text: str) -> float:
    units = {"s": 1, "m": 60, "h": 3600}
    if text and text[-1] in units:
        return float(text[:-1]) * units[text[-1]]
    return float(text)


def signal_group(group: int, sig: int) -> bool:
    """Sends sig to the group; False when no process is left in it."""
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        return False
    return True


def finish(child: subprocess.Popen, kill_after) -> None:
    """Waits for the signalled command; with kill_after, KILLs what is left of its group."""
    if kill_after is None:
        child.wait()
        return
    deadline = time.monotonic() + kill_after
    # Reap the command as it exits (a zombie would keep the group alive), and give the
    # rest of the group the same grace before the KILL.
    while time.monotonic() < deadline:
        child.poll()
        if not signal_group(child.pid, 0):
            break
        time.sleep(0.01)
    else:
        signal_group(child.pid, signal.SIGKILL)
    child.wait()


def main(argv: list) -> int:
    sig, kill_after = signal.SIGTERM, None
    while argv and argv[0].startswith("--"):
        option, _, value = argv.pop(0).partition("=")
        if option == "--signal":
            sig = signal.Signals["SIG" + value.removeprefix("SIG")]
        elif option == "--kill-after":
            kill_after = seconds(value)
        else:
            print(f"timeout.py: unsupported option {option}", file=sys.stderr)
            return 125
    if len(argv) < 2:
        print("usage: timeout.py [--signal=NAME] [--kill-after=DURATION] DURATION COMMAND...", file=sys.stderr)
        return 125
    budget = seconds(argv[0])
    child = None
    received = []

    def forward(signum, _frame):
        if child is None:
            # Before the command started: nothing to forward to, so stop here.
            sys.exit(128 + signum)
        signal_group(child.pid, signum)
        if not received:
            received.append(signum)
            raise Forwarded()

    for forwarded in FORWARDED:
        signal.signal(forwarded, forward)
    try:
        # Its own session, so its process group holds the command and its descendants only.
        child = subprocess.Popen(argv[1:], start_new_session=True)
    except OSError as error:
        print(f"timeout.py: {error}", file=sys.stderr)
        return 127
    try:
        status = child.wait(timeout=budget)
    except subprocess.TimeoutExpired:
        signal_group(child.pid, sig)
        finish(child, kill_after)
        return 124
    except Forwarded:
        finish(child, kill_after)
        status = child.returncode
    return 128 - status if status < 0 else status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

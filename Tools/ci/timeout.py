#!/usr/bin/env python3
"""The subset of GNU `timeout` that Tools/ci/ui-shard.sh uses, for a Mac without coreutils.

    timeout.py [--signal=NAME] [--kill-after=DURATION] DURATION COMMAND [ARG...]

macOS ships no `timeout`, and macserve's job PATH has no Homebrew `gtimeout`. Like GNU
timeout: DURATION is a number with an optional s, m or h suffix; when it runs out the
command gets NAME (default TERM), then KILL after --kill-after if it is still running;
the exit status is 124 when the time ran out, else the command's own status (128 + N
for a command killed by signal N).
"""
import signal
import subprocess
import sys


def seconds(text: str) -> float:
    units = {"s": 1, "m": 60, "h": 3600}
    if text and text[-1] in units:
        return float(text[:-1]) * units[text[-1]]
    return float(text)


def main(argv: list[str]) -> int:
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
    try:
        child = subprocess.Popen(argv[1:])
    except OSError as error:
        print(f"timeout.py: {error}", file=sys.stderr)
        return 127
    try:
        status = child.wait(timeout=budget)
    except subprocess.TimeoutExpired:
        child.send_signal(sig)
        try:
            child.wait(timeout=kill_after)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        return 124
    return 128 - status if status < 0 else status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Follows one xcodebuild test run's log for Tools/ci/ui-shard.sh and stops the run when its
simulator stopped answering accessibility. Linux-testable: Tools/ci/test_ci_helpers.py.

    ax-watch.py LOG PID STOP

Copies LOG to stdout as it grows (the round's console, through xcbeautify) until the file
STOP.done exists, then copies the rest and exits 0. When AX_LIMIT (3) test cases in a row
fail with an accessibility or automation time-out, it writes their names to STOP, one per
line, and sends SIGINT to PID (the round's timeout process, which passes it on to
xcodebuild's process group; its --kill-after ends the rest). A test case that passes, is
skipped, or fails any other way starts the count again.

Herdrup #674's ipad-script job j_1b3bd71b: after four passing references, the 13-inch
iPad's accessibility stopped answering, and five DesktopReferenceShots cases in a row
failed after 150-170 s each on "Failed to get screenshot: Timed out while requesting
screenshot." and "Failed to get list of active applications: Accessibility error
kAXErrorIPCTimeout from AXUIElementCopyMultipleAttributeValues ...". The rest of that
round and the next one ran out their 15m and 20m budgets on the same dead device.
"""
import os
import re
import signal
import sys
import time

AX_LIMIT = 3
STARTED = re.compile(r"^Test Case '-\[(?P<name>[^\]]+)\]' started\.")
FINISHED = re.compile(r"^Test Case '-\[(?P<name>[^\]]+)\]' (?P<result>passed|failed|skipped) \(")
ISSUE = re.compile(r": error: -\[(?P<name>[^\]]+)\] : (?P<message>.*)")
# The messages XCTest's automation prints when the simulator's accessibility does not answer.
AX_TIMEOUT = re.compile(
    r"Failed to get screenshot: Timed out"
    r"|Failed to get list of active applications"
    r"|Timed out while requesting"
    r"|Accessibility error"
    r"|kAXErrorIPCTimeout"
)
POLL = 0.2


def case_name(raw):
    """`HerdrUITests.DesktopReferenceShots testFolders` -> `DesktopReferenceShots/testFolders`."""
    suite, _, method = raw.partition(" ")
    return "%s/%s" % (suite.rpartition(".")[2], method)


class Watch:
    def __init__(self, stop, pid):
        self.stop, self.pid = stop, pid
        self.timed_out = set()
        self.streak = []
        self.stopped = False

    def line(self, text):
        issue = ISSUE.search(text)
        if issue and AX_TIMEOUT.search(issue["message"]):
            self.timed_out.add(issue["name"])
            return
        finished = FINISHED.match(text)
        if not finished:
            return
        name = finished["name"]
        if finished["result"] == "failed" and name in self.timed_out:
            self.streak.append(case_name(name))
        else:
            self.streak = []
        self.timed_out.discard(name)
        if len(self.streak) >= AX_LIMIT and not self.stopped:
            self.stopped = True
            with open(self.stop, "w") as target:
                target.write("\n".join(self.streak) + "\n")
            try:
                os.kill(self.pid, signal.SIGINT)
            except ProcessLookupError:
                pass


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 64
    log, pid, stop = argv[1], int(argv[2]), argv[3]
    done = stop + ".done"
    watch = Watch(stop, pid)
    pending = ""
    with open(log, errors="replace") as source:
        while True:
            finished = os.path.exists(done)
            chunk = source.read()
            if chunk:
                sys.stdout.write(chunk)
                sys.stdout.flush()
                pending += chunk
                *lines, pending = pending.split("\n")
                for text in lines:
                    watch.line(text)
            elif finished:
                if pending:
                    watch.line(pending)
                return 0
            else:
                time.sleep(POLL)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        sys.exit(0)

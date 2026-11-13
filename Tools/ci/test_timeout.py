#!/usr/bin/env python3
"""Tools/ci/timeout.py ends the timed command's descendants too. Linux, seconds:
Tools/ci/check.sh runs it in CI's Linux job.

A descendant that outlived the deadline held the output pipe open, so the timed round did
not end at its budget (review of #663, F1: 124 after 2.022 s for a 0.1 s budget, where
GNU timeout took 0.104 s)."""
import os
import pathlib
import subprocess
import sys
import time
import unittest

TIMEOUT = pathlib.Path(__file__).resolve().parent / "timeout.py"


def gone(pid: int, within: float = 1.0) -> bool:
    """True once pid no longer exists (its new parent may take a moment to reap it)."""
    end = time.monotonic() + within
    while time.monotonic() < end:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.01)
    return False


class TimeoutTests(unittest.TestCase):
    def timed(self, *argv):
        """Runs timeout.py with captured output, as a `| tee` round does; returns (status,
        seconds from the command's first output to timeout.py's exit, the descendant pid the
        command printed). Timed from the output, so the interpreter's start-up is not counted."""
        process = subprocess.Popen([sys.executable, str(TIMEOUT), *argv], stdout=subprocess.PIPE, text=True)
        pid = int(process.stdout.readline())
        start = time.monotonic()
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            os.kill(pid, 9)
            process.kill()
            process.communicate()
            self.fail("the output pipe stayed open after the deadline: descendant %d outlived it" % pid)
        return process.returncode, time.monotonic() - start, pid

    def test_a_backgrounded_descendant_ends_with_the_deadline(self):
        status, elapsed, pid = self.timed("0.1s", "bash", "-c", "sleep 30 & echo $!; wait")
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 0.5)
        self.assertTrue(gone(pid), "descendant %d survived the deadline" % pid)

    def test_kill_after_kills_a_descendant_that_ignores_the_signal(self):
        # `trap "" TERM` is inherited: the backgrounded sleep ignores TERM as well.
        status, elapsed, pid = self.timed("--kill-after=0.2s", "0.1s", "bash", "-c", 'trap "" TERM; sleep 30 & echo $!; wait')
        self.assertEqual(status, 124)
        self.assertLess(elapsed, 0.8)
        self.assertTrue(gone(pid), "descendant %d survived the KILL" % pid)

    def test_the_command_status_passes_through(self):
        self.assertEqual(subprocess.run([sys.executable, str(TIMEOUT), "5", "sh", "-c", "exit 7"]).returncode, 7)


if __name__ == "__main__":
    unittest.main()

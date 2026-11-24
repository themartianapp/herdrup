#!/usr/bin/env python3
"""Tools/ci/timeout.py ends the timed command's descendants too. Linux, seconds:
Tools/ci/check.sh runs it in CI's Linux job.

A descendant that outlived the deadline held the output pipe open, so the timed round did
not end at its budget (review of #663, F1: 124 after 2.022 s for a 0.1 s budget, where
GNU timeout took 0.104 s)."""
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
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

    def test_an_int_sent_to_a_backgrounded_timeout_reaches_the_command(self):
        # As ui-shard.sh's accessibility watcher stops a round: timeout.py started with `&`
        # (INT ignored, as in any script's background job) gets SIGINT and passes it on.
        ready = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory())) / "ready"
        script = ('"$PY" "$TIMEOUT" --signal=INT --kill-after=5s 60s bash -c '
                  '\'trap "echo got-int; exit 3" INT; : >"$READY"; for _ in $(seq 200); do sleep 0.05; done\' & '
                  'pid=$!; while [ ! -e "$READY" ]; do sleep 0.02; done; kill -INT "$pid"; '
                  'wait "$pid"; echo "status $?"')
        process = subprocess.Popen(["bash", "-c", script], stdout=subprocess.PIPE, text=True,
                                   env=dict(os.environ, PY=sys.executable, TIMEOUT=str(TIMEOUT), READY=str(ready)))
        try:
            out, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            self.fail("the INT did not end the timed command")
        self.assertIn("got-int", out)
        self.assertIn("status 3", out)

    def test_a_signal_during_the_grace_after_a_time_out_keeps_the_kill(self):
        # Review of #748, P2-b: the budget ran out, the command ignores TERM and INT, and an
        # INT reaches timeout.py during the kill-after grace (the accessibility watcher
        # stopping a round that is already timing out). The KILL must still come.
        process = subprocess.Popen(
            [sys.executable, str(TIMEOUT), "--kill-after=1s", "0.2s", "bash", "-c",
             'trap "" INT TERM; echo $$; while :; do sleep 0.05; done'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        pid = int(process.stdout.readline())
        time.sleep(0.5)  # past the 0.2 s budget, inside the 1 s grace
        process.send_signal(signal.SIGINT)
        try:
            _, err = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.kill(pid, signal.SIGKILL)
            process.kill()
            process.communicate()
            self.fail("timeout.py did not end after its KILL deadline")
        alive = not gone(pid)
        if alive:
            os.kill(pid, signal.SIGKILL)
        self.assertEqual(process.returncode, 124, err)
        self.assertFalse(alive, "the command survived the KILL deadline")
        self.assertNotIn("Traceback", err)

    def test_a_signal_that_ends_the_command_still_kills_the_rest_of_its_group(self):
        # Re-review of #748: a TERM forwarded to the group ends the command at once (a
        # Python parent with the default TERM action), while its descendant ignores TERM.
        # The wrapper must still give the group its grace and KILL it, not return the
        # command's 143 and leave the descendant running.
        work = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        ready = work / "descendant.pid"
        parent = ("import subprocess, sys\n"
                  "subprocess.Popen(['bash', '-c', 'trap \"\" TERM; echo $$ >\"$READY.tmp\"; "
                  "mv \"$READY.tmp\" \"$READY\"; while :; do sleep 0.05; done'])\n"
                  "subprocess.run(['sleep', '60'])\n")
        # stderr to a file, not a pipe: a surviving descendant would hold a pipe open.
        errors = work / "stderr.txt"
        with errors.open("w") as stderr:
            process = subprocess.Popen(
                [sys.executable, str(TIMEOUT), "--kill-after=0.2s", "60s", sys.executable, "-c", parent],
                stdout=subprocess.DEVNULL, stderr=stderr, env=dict(os.environ, READY=str(ready)))
        end = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < end:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "the descendant did not start")
        pid = int(ready.read_text())
        start = time.monotonic()
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.kill(pid, signal.SIGKILL)
            process.kill()
            process.wait()
            self.fail("timeout.py did not end after its KILL deadline")
        elapsed = time.monotonic() - start
        err = errors.read_text()
        alive = not gone(pid)
        if alive:
            os.kill(pid, signal.SIGKILL)
        self.assertEqual(process.returncode, 143, err)
        self.assertFalse(alive, "the descendant survived the KILL deadline (wrapper returned after %.3f s)" % elapsed)
        self.assertGreaterEqual(elapsed, 0.2, "the wrapper returned before the kill-after grace")

    def test_a_group_member_it_may_not_signal_does_not_crash_the_cleanup(self):
        # macserve 2026-11-24 (job j_0acf5df2…): os.killpg(group, 0) raised EPERM in finish(),
        # and the wrapper crashed instead of finishing the cleanup and reporting the status.
        import importlib.util
        from unittest import mock
        spec = importlib.util.spec_from_file_location("ci_timeout", TIMEOUT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        child = subprocess.Popen(["true"], start_new_session=True)
        with mock.patch.object(module.os, "killpg", side_effect=PermissionError(1, "Operation not permitted")):
            self.assertTrue(module.signal_group(child.pid, 0), "EPERM means the group still exists")
            module.finish(child, 0.1)
        self.assertEqual(child.returncode, 0)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Focused deadline, reaping, settle, and schema tests for the parity harness."""
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).with_name("keywork_wayland_benchmark.py")
SPEC = importlib.util.spec_from_file_location("keywork_wayland_benchmark", SCRIPT)
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


class HarnessTests(unittest.TestCase):
    def spawn_writer(self, program):
        process = subprocess.Popen(
            [sys.executable, "-c", program],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        return process, benchmark.DeadlineLineReader(process.stdout)

    def cleanup(self, process):
        benchmark.reap_process(process, 0.05, True)
        benchmark.close_process_streams(process)

    def test_partial_line_obeys_deadline_and_child_is_reaped(self):
        process, reader = self.spawn_writer("import sys,time;sys.stdout.write('X');sys.stdout.flush();time.sleep(.5)")
        started = time.monotonic()
        try:
            with self.assertRaises(TimeoutError):
                reader.read_line(started + 0.05, "partial line")
            self.assertLess(time.monotonic() - started, 0.2)
        finally:
            self.cleanup(process)
        self.assertIsNotNone(process.returncode)
        with self.assertRaises(ChildProcessError):
            os.waitpid(process.pid, os.WNOHANG)

    def test_line_reader_rejects_partial_eof_invalid_utf8_and_oversize(self):
        cases = (
            ("import os;os.write(1,b'partial')", EOFError, 64),
            ("import os;os.write(1,b'\\xff\\n')", ValueError, 64),
            ("import os;os.write(1,b'123456789\\n')", ValueError, 8),
        )
        for program, expected, maximum in cases:
            with self.subTest(expected=expected, maximum=maximum):
                process, reader = self.spawn_writer(program)
                reader.max_line_bytes = maximum
                try:
                    with self.assertRaises(expected):
                        reader.read_line(time.monotonic() + 1, "invalid line")
                finally:
                    self.cleanup(process)

    def test_reap_kills_term_ignoring_child_and_handles_already_exited_child(self):
        stubborn = subprocess.Popen(
            [sys.executable, "-c", "import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(10)"],
            start_new_session=True,
        )
        time.sleep(0.05)
        self.assertEqual(-signal.SIGKILL, benchmark.reap_process(stubborn, 0.02, True))
        with self.assertRaises(ChildProcessError):
            os.waitpid(stubborn.pid, os.WNOHANG)

        exited = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
        time.sleep(0.05)
        self.assertEqual(0, benchmark.reap_process(exited, 0.02, True))

    def test_settle_waits_for_fd_baseline(self):
        program = """
import sys,time
print('READY',flush=True)
sys.stdin.buffer.read(1)
extra=open('/dev/null','rb')
print('OPEN',flush=True)
time.sleep(.08)
extra.close()
time.sleep(10)
"""
        process, reader = self.spawn_writer(program)
        try:
            self.assertEqual("READY", reader.read_line(time.monotonic() + 1, "settle readiness"))
            baseline = benchmark.process_snapshot(process.pid)["fds"]
            process.stdin.write(b"x")
            process.stdin.flush()
            self.assertEqual("OPEN", reader.read_line(time.monotonic() + 1, "settle open"))
            settled = benchmark.wait_server_settled(process, baseline, time.monotonic() + 1)
            self.assertEqual(baseline, settled["fds"])
        finally:
            self.cleanup(process)

    def test_schema_and_named_runtime_leftovers(self):
        row = {field: 1 for field in benchmark.REQUIRED_SAMPLE_FIELDS}
        row["runtime_leftovers_after_teardown_json"] = "[]"
        benchmark.validate_sample(row)
        del row["active_after_fds"]
        with self.assertRaises(ValueError):
            benchmark.validate_sample(row)

        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory)
            (runtime / "keywork").mkdir()
            (runtime / "keywork" / "state").write_text("x")
            leftovers = benchmark.runtime_leftovers(runtime)
            self.assertEqual(
                [{"path": "keywork", "type": "directory"}, {"path": "keywork/state", "type": "regular"}],
                leftovers,
            )
            json.dumps(leftovers)


if __name__ == "__main__":
    unittest.main()

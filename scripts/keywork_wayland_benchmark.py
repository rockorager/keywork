#!/usr/bin/env python3
"""P3-H Wave 0 same-binary Keywork Wayland-server parity harness (no claims)."""
import argparse
import csv
import json
import os
import platform
import random
import select
import signal
import socket
import stat
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_LINE_BYTES = 64 * 1024
RESOURCE_COUNTERS = ("user_ticks", "system_ticks", "minor_faults", "major_faults", "voluntary_ctxt", "involuntary_ctxt")
BOUNDARY_SNAPSHOTS = ("idle_before", "idle_after", "active_before", "active_after", "settled")
RESOURCE_INTERVALS = {
    "idle": "idle_before to idle_after; no clients exist",
    "warmup": "idle_after to active_before; clients spawn, connect, and warm up",
    "active": "active_before to active_after; cleanup-gated clients execute only the measured workload",
    "cleanup": "active_after to settled; clients disconnect and are reaped, then server FD count equals the idle baseline for three polls",
}
REQUIRED_SAMPLE_FIELDS = {
    "selector", "workload", "operations", "wall_ns", "throughput_ops_s",
    "startup_connectable_ns", "startup_stdout_ns", "idle_wall_ns", "warmup_wall_ns", "cleanup_wall_ns",
    "runtime_leftovers_after_teardown_json", "parent_fd_before", "parent_fd_after",
    *(f"{boundary}_{metric}" for boundary in BOUNDARY_SNAPSHOTS for metric in ("fds", "rss_kb", "hwm_kb")),
    *(f"{interval}_{metric}" for interval in RESOURCE_INTERVALS for metric in
      ("cpu_user_ns", "cpu_system_ns", "minor_faults", "major_faults", "voluntary_ctxt", "involuntary_ctxt")),
}


class DeadlineLineReader:
    """Reads strict UTF-8 lines from a nonblocking binary pipe by a fixed deadline."""

    def __init__(self, stream, max_line_bytes=MAX_LINE_BYTES):
        self.stream = stream
        self.fd = stream.fileno()
        self.buffer = bytearray()
        self.max_line_bytes = max_line_bytes
        os.set_blocking(self.fd, False)

    def read_line(self, deadline, description):
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                if newline + 1 > self.max_line_bytes:
                    raise ValueError(f"{description} exceeded {self.max_line_bytes} bytes")
                raw = bytes(self.buffer[:newline])
                del self.buffer[:newline + 1]
                if raw.endswith(b"\r"):
                    raw = raw[:-1]
                try:
                    return raw.decode("utf-8", "strict")
                except UnicodeDecodeError as error:
                    raise ValueError(f"{description} was not valid UTF-8") from error
            if len(self.buffer) >= self.max_line_bytes:
                raise ValueError(f"{description} exceeded {self.max_line_bytes} bytes without newline")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for {description}")
            if not select.select([self.fd], [], [], remaining)[0]:
                raise TimeoutError(f"timed out waiting for {description}")
            try:
                chunk = os.read(self.fd, min(4096, self.max_line_bytes + 1 - len(self.buffer)))
            except BlockingIOError:
                continue
            if not chunk:
                if self.buffer:
                    raise EOFError(f"EOF while reading partial {description}")
                raise EOFError(f"EOF while waiting for {description}")
            self.buffer.extend(chunk)


def process_snapshot(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    status = dict(line.split(":", 1) for line in Path(f"/proc/{pid}/status").read_text().splitlines() if ":" in line)
    number = lambda key: int(status.get(key, " 0").strip().split()[0])
    return {
        "user_ticks": int(fields[13]), "system_ticks": int(fields[14]),
        "minor_faults": int(fields[9]), "major_faults": int(fields[11]),
        "rss_kb": number("VmRSS"), "hwm_kb": number("VmHWM"),
        "voluntary_ctxt": number("voluntary_ctxt_switches"),
        "involuntary_ctxt": number("nonvoluntary_ctxt_switches"),
        "fds": len(list(Path(f"/proc/{pid}/fd").iterdir())),
    }


def resource_delta(prefix, before, after):
    tick_ns = 1_000_000_000 // os.sysconf("SC_CLK_TCK")
    return {
        f"{prefix}_cpu_user_ns": (after["user_ticks"] - before["user_ticks"]) * tick_ns,
        f"{prefix}_cpu_system_ns": (after["system_ticks"] - before["system_ticks"]) * tick_ns,
        **{f"{prefix}_{key}": after[key] - before[key] for key in RESOURCE_COUNTERS[2:]},
    }


def boundary_fields(name, snapshot):
    return {f"{name}_{key}": snapshot[key] for key in ("fds", "rss_kb", "hwm_kb")}


def signal_process_group(process, kind):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, kind)
    except ProcessLookupError:
        pass


def reap_process(process, graceful_timeout, terminate):
    """Returns only after wait() has reaped process; SIGKILL is the bounded fallback."""
    if terminate:
        signal_process_group(process, signal.SIGTERM)
    try:
        return process.wait(timeout=max(0.0, graceful_timeout))
    except subprocess.TimeoutExpired:
        signal_process_group(process, signal.SIGKILL)
        return process.wait()


def close_process_streams(process):
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None and not stream.closed:
            stream.close()


def wait_socket(runtime, process, deadline):
    started = time.monotonic_ns()
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"compositor exited {process.returncode} before becoming connectable")
        for path in runtime.glob("wayland-[0-9]*"):
            if not path.is_socket():
                continue
            try:
                connect_socket(path)
                return path, time.monotonic_ns() - started
            except OSError:
                pass
        time.sleep(min(0.005, max(0.0, deadline - time.monotonic())))
    raise TimeoutError("compositor did not become connectable")


def wait_display_name(reader, deadline):
    line = reader.read_line(deadline, "canonical display name")
    if not line.startswith("WAYLAND_DISPLAY="):
        raise RuntimeError(f"unexpected first compositor output: {line!r}")
    return line.split("=", 1)[1]


def connect_socket(path):
    with socket.socket(socket.AF_UNIX) as probe:
        probe.connect(str(path))


def public_sockets(runtime):
    return sorted(path for path in runtime.glob("wayland-[0-9]*") if path.is_socket())


def run_registry_client(args, path):
    command = [str(args.client), str(path), "registry", "1", "1", "1"]
    client = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    reader = DeadlineLineReader(client.stdout)
    try:
        deadline = time.monotonic() + args.timeout
        if reader.read_line(deadline, "registry client readiness") != "READY":
            raise RuntimeError("registry client emitted an invalid readiness line")
        client.stdin.write(b"x")
        client.stdin.flush()
        result = json.loads(reader.read_line(deadline, "registry client result"))
        return_code = reap_process(client, max(0.0, deadline - time.monotonic()), False)
        if return_code != 0 or result["operations"] != 1:
            error = client.stderr.read().decode("utf-8", "replace")
            raise RuntimeError(f"external registry client failed: {error}")
    finally:
        reap_process(client, 0.1, True)
        close_process_streams(client)


def drain_lines(reader, deadline):
    lines = []
    while True:
        try:
            lines.append(reader.read_line(deadline, "compositor output"))
        except EOFError as error:
            if "partial" in str(error):
                raise
            return lines


def lifecycle_check(args):
    checks = []
    with tempfile.TemporaryDirectory(prefix="keywork-parity-lifecycle-") as directory:
        base = Path(directory)
        runtime = base / "runtime"
        runtime.mkdir(mode=0o700)
        cases = (
            ("wayring", ["--wayland-server", "wayring"], 1),
            ("libwayland", ["--wayland-server", "libwayland"], 1),
            ("wayring", ["--wayland-server", "wayring"], 1),
            ("dual", ["--wayland-server", "dual"], 2),
            ("deprecated-alias", ["--experimental-wayring"], 2),
        )
        for index, (label, selector_args, expected_sockets) in enumerate(cases):
            if public_sockets(runtime) or list(runtime.glob("wayland-[0-9]*.lock")):
                raise RuntimeError(f"public Wayland paths survived before {label}")
            environment = os.environ.copy()
            environment.update(XDG_RUNTIME_DIR=str(runtime), KEYWORK_WAYRING_DISPLAY="stale-parent-value")
            command = [str(args.compositor), "--output", "headless", *selector_args]
            log = open(base / f"{index}-{label}.log", "wb")
            server = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
            reader = DeadlineLineReader(server.stdout)
            try:
                deadline = time.monotonic() + args.timeout
                wait_socket(runtime, server, deadline)
                canonical = wait_display_name(reader, deadline)
                canonical_path = runtime / canonical
                connect_socket(canonical_path)
                sockets = public_sockets(runtime)
                if len(sockets) != expected_sockets or canonical_path not in sockets:
                    raise RuntimeError(f"{label}: canonical={canonical!r}, public sockets={[path.name for path in sockets]}")
                run_registry_client(args, canonical_path)
                output = [f"WAYLAND_DISPLAY={canonical}"]
                sidecars = []
                expects_sidecar = label in ("dual", "deprecated-alias")
                if expects_sidecar:
                    sidecar_line = reader.read_line(deadline, "Wayring sidecar display name")
                    if not sidecar_line.startswith("KEYWORK_WAYRING_DISPLAY="):
                        raise RuntimeError(f"{label}: unexpected second output line {sidecar_line!r}")
                    output.append(sidecar_line)
                    sidecars.append(sidecar_line.split("=", 1)[1])
                    sidecar_path = runtime / sidecars[0]
                    if sidecar_path == canonical_path or sidecar_path not in sockets:
                        raise RuntimeError(f"{label}: invalid sidecar display {sidecars[0]!r}")
                    run_registry_client(args, sidecar_path)
                return_code = reap_process(server, max(0.0, deadline - time.monotonic()), True)
                if return_code != 0:
                    raise RuntimeError(f"{label}: compositor exited {return_code}")
                output.extend(drain_lines(reader, time.monotonic() + 1))
                emitted_sidecars = [line.split("=", 1)[1] for line in output if line.startswith("KEYWORK_WAYRING_DISPLAY=")]
                if expects_sidecar != (emitted_sidecars == sidecars and len(sidecars) == 1):
                    raise RuntimeError(f"{label}: unexpected output lines {output!r}")
                checks.append({"case": label, "command": command, "canonical_display": canonical,
                               "public_sockets": [path.name for path in sockets], "stdout": output,
                               "registry_connected": [canonical, *sidecars], "exit_code": return_code})
            finally:
                reap_process(server, 0.5, True)
                close_process_streams(server)
                log.close()
            leftovers = [path.name for path in runtime.glob("wayland-[0-9]*")]
            if leftovers:
                raise RuntimeError(f"{label}: owned Wayland paths survived teardown: {leftovers}")
    return checks


def wait_server_settled(process, expected_fds, deadline, stable_polls=3):
    stable = 0
    last = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"compositor exited {process.returncode} before settling")
        last = process_snapshot(process.pid)
        stable = stable + 1 if last["fds"] == expected_fds else 0
        if stable == stable_polls:
            return last
        time.sleep(min(0.01, max(0.0, deadline - time.monotonic())))
    actual = None if last is None else last["fds"]
    raise TimeoutError(f"compositor did not settle to {expected_fds} FDs (last={actual})")


def runtime_leftovers(runtime):
    leftovers = []
    for path in sorted(runtime.rglob("*")):
        mode = path.lstat().st_mode
        kind = ("directory" if stat.S_ISDIR(mode) else "socket" if stat.S_ISSOCK(mode) else
                "regular" if stat.S_ISREG(mode) else "symlink" if stat.S_ISLNK(mode) else "other")
        leftovers.append({"path": str(path.relative_to(runtime)), "type": kind})
    return leftovers


def validate_sample(row):
    missing = REQUIRED_SAMPLE_FIELDS - row.keys()
    if missing:
        raise ValueError(f"sample schema missing fields: {sorted(missing)}")
    if row["operations"] <= 0 or row["wall_ns"] <= 0:
        raise ValueError("sample operation and wall counts must be positive")


def run_sample(args, selector, workload, repetition, pair, position):
    with tempfile.TemporaryDirectory(prefix="keywork-parity-") as directory:
        base = Path(directory)
        runtime = base / "runtime"
        runtime.mkdir(mode=0o700)
        environment = os.environ.copy()
        environment["XDG_RUNTIME_DIR"] = str(runtime)
        command = [str(args.compositor), "--output", "headless", "--wayland-server", selector]
        log = open(base / "compositor.log", "wb")
        parent_fds_before = len(list(Path("/proc/self/fd").iterdir()))
        started_ns = time.monotonic_ns()
        server = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=log, start_new_session=True)
        server_reader = DeadlineLineReader(server.stdout)
        clients = []
        try:
            startup_deadline = time.monotonic() + args.timeout
            path, connectable_ns = wait_socket(runtime, server, startup_deadline)
            canonical_display = wait_display_name(server_reader, startup_deadline)
            startup_stdout_ns = time.monotonic_ns() - started_ns
            if canonical_display != path.name:
                raise RuntimeError(f"emitted {canonical_display!r}, connected to {path.name!r}")

            idle_before = process_snapshot(server.pid)
            idle_started_ns = time.monotonic_ns()
            time.sleep(args.idle_ms / 1000)
            idle_wall_ns = time.monotonic_ns() - idle_started_ns
            idle_after = process_snapshot(server.pid)

            quotient, remainder = divmod(args.operations, args.concurrency)
            client_commands = []
            client_readers = []
            warmup_started_ns = time.monotonic_ns()
            for index in range(args.concurrency):
                count = quotient + (1 if index < remainder else 0)
                client_command = [str(args.client), str(path), workload, str(count), str(args.warmup), "1", "cleanup-gate"]
                client_commands.append(client_command)
                client = subprocess.Popen(client_command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, start_new_session=True)
                clients.append(client)
                client_readers.append(DeadlineLineReader(client.stdout))
            ready_deadline = time.monotonic() + args.timeout
            for client_reader in client_readers:
                if client_reader.read_line(ready_deadline, "client readiness") != "READY":
                    raise RuntimeError("client emitted an invalid readiness line")
            active_before = process_snapshot(server.pid)
            warmup_wall_ns = time.monotonic_ns() - warmup_started_ns

            active_started_ns = time.monotonic_ns()
            for client in clients:
                client.stdin.write(b"x")
                client.stdin.flush()
            result_deadline = time.monotonic() + args.timeout
            results = [json.loads(reader.read_line(result_deadline, "client result")) for reader in client_readers]
            wall_ns = time.monotonic_ns() - active_started_ns
            active_after = process_snapshot(server.pid)

            cleanup_started_ns = time.monotonic_ns()
            for client in clients:
                client.stdin.write(b"y")
                client.stdin.flush()
            completion_deadline = time.monotonic() + args.timeout
            for client in clients:
                return_code = reap_process(client, max(0.0, completion_deadline - time.monotonic()), False)
                if return_code != 0:
                    error = client.stderr.read().decode("utf-8", "replace")
                    raise RuntimeError(f"benchmark client exited {return_code}: {error}")
                close_process_streams(client)
            settled = wait_server_settled(server, idle_after["fds"], time.monotonic() + args.timeout)
            cleanup_wall_ns = time.monotonic_ns() - cleanup_started_ns

            teardown_started_ns = time.monotonic_ns()
            return_code = reap_process(server, args.timeout, True)
            teardown_ns = time.monotonic_ns() - teardown_started_ns
            if return_code != 0:
                raise RuntimeError(f"compositor exited {return_code}")
            close_process_streams(server)
            leftovers = runtime_leftovers(runtime)
            parent_fds_after = len(list(Path("/proc/self/fd").iterdir()))

            operations = sum(result["operations"] for result in results)
            row = {
                "selector": selector, "mode": selector, "workload": workload, "repetition": repetition,
                "pair": pair, "order_position": position, "concurrency": args.concurrency,
                "operations": operations, "wall_ns": wall_ns, "throughput_ops_s": operations * 1e9 / wall_ns,
                "startup_connectable_ns": connectable_ns, "startup_stdout_ns": startup_stdout_ns,
                "canonical_display": canonical_display, "idle_requested_ms": args.idle_ms,
                "idle_wall_ns": idle_wall_ns, "warmup_wall_ns": warmup_wall_ns,
                "cleanup_wall_ns": cleanup_wall_ns, "teardown_ns": teardown_ns,
                "runtime_leftovers_after_teardown_json": json.dumps(leftovers, separators=(",", ":")),
                "parent_fd_before": parent_fds_before, "parent_fd_after": parent_fds_after,
            }
            for name, snapshot in (("idle_before", idle_before), ("idle_after", idle_after),
                                   ("active_before", active_before), ("active_after", active_after),
                                   ("settled", settled)):
                row.update(boundary_fields(name, snapshot))
            for name, before, after in (("idle", idle_before, idle_after), ("warmup", idle_after, active_before),
                                        ("active", active_before, active_after), ("cleanup", active_after, settled)):
                row.update(resource_delta(name, before, after))
            validate_sample(row)
            return row, command, client_commands
        finally:
            for client in clients:
                reap_process(client, 0.2, True)
                close_process_streams(client)
            reap_process(server, 0.5, True)
            close_process_streams(server)
            log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compositor", type=Path, default=ROOT / "zig-out/bin/keywork-compositor")
    parser.add_argument("--client", type=Path, default=ROOT / "zig-out/wayring-benchmark/wayring-benchmark-client")
    parser.add_argument("--output-dir", type=Path, default=ROOT / ".amp/in/artifacts/keywork-wayland-parity")
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--operations", type=int, default=1000)
    parser.add_argument("--warmup", type=int, default=10)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--workloads", nargs="+", choices=("serial", "pipeline", "registry", "churn"),
                        default=("serial", "pipeline", "registry", "churn"))
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--idle-ms", type=int, default=100)
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--dedicated-machine", choices=("yes", "no", "unknown"), default="unknown")
    args = parser.parse_args()
    if args.operations < 1 or args.concurrency < 1 or args.concurrency > args.operations:
        parser.error("require operations >= concurrency >= 1")
    if args.timeout <= 0 or args.idle_ms < 0:
        parser.error("require timeout > 0 and idle-ms >= 0")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    lifecycle = lifecycle_check(args)
    rng = random.Random(args.seed)
    rows = []
    commands = []
    for workload in args.workloads:
        for repetition in range(1, args.repetitions + 1):
            order = ["libwayland", "wayring"]
            rng.shuffle(order)
            for position, selector in enumerate(order, 1):
                row, server_command, client_commands = run_sample(
                    args, selector, workload, repetition, f"{workload}-{repetition}", position,
                )
                rows.append(row)
                commands.append({"server": server_command, "clients": client_commands})
                print(json.dumps(row))

    with open(args.output_dir / "raw.csv", "w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=rows[0])
        writer.writeheader()
        writer.writerows(rows)
    version = subprocess.run([str(args.compositor), "--version"], text=True, capture_output=True)
    git_commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, capture_output=True).stdout.strip()
    git_tree = subprocess.run(["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT, text=True, capture_output=True).stdout.strip()
    git_dirty = bool(subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, text=True, capture_output=True).stdout)
    metadata = {
        "purpose": "same ReleaseSafe Keywork binary/config selector harness; no comparative claim",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "selectors": ["libwayland", "wayring"], "fixed_arguments": ["--output", "headless"],
        "no_sidecar": True, "repetitions": args.repetitions, "random_seed": args.seed,
        "order": "randomized AB/BA per workload/repetition", "requested_operations": args.operations,
        "warmup": args.warmup, "concurrency": args.concurrency, "dedicated_machine": args.dedicated_machine,
        "kernel": platform.release(), "platform": platform.platform(), "machine": platform.machine(),
        "cpu_count": os.cpu_count(), "python": platform.python_version(),
        "zig": subprocess.check_output(["zig", "version"], text=True).strip(),
        "compositor_version": (version.stdout + version.stderr).strip(),
        "git_commit": git_commit, "git_tree": git_tree, "git_worktree_dirty": git_dirty,
        "commands": commands, "lifecycle_check": lifecycle,
        "environment": {"XDG_RUNTIME_DIR": "per-sample private temporary directory"},
        "resource_boundaries": RESOURCE_INTERVALS,
        "settle_condition": "all workload clients reaped, then compositor FD count equals idle_after_fds for three 10ms polls",
        "throughput_interval": "cleanup-gated release through receipt of every complete result line; excludes spawn/warmup/disconnect",
        "runtime_leftovers_field": "runtime_leftovers_after_teardown_json contains every recursive relative path and file type",
        "unavailable_counters": ["hardware performance counters"],
        "unimplemented_workloads": ["basic SHM/XDG lifecycle (production fixture exposes no generated xdg-shell client API)"],
    }
    (args.output_dir / "raw.json").write_text(json.dumps({"metadata": metadata, "samples": rows}, indent=2) + "\n")
    report = """# P3-H Wave 0 raw parity harness

No comparative claim is made. Both selectors use the exact same ReleaseSafe Keywork compositor artifact and headless configuration, without a sidecar.

`wall_ns` and throughput cover only cleanup-gated measured work: all clients are connected and warmed before release, and remain connected until `active_after` is sampled. Resource deltas are separately labeled `idle`, `warmup`, `active`, and `cleanup`; their exact boundaries are in `raw.json`. Cleanup reaches `settled` only after every workload client is reaped and compositor FDs equal the post-idle baseline for three polls. Post-teardown runtime leftovers are named and typed in each row's JSON field. Hardware counters and SHM/XDG lifecycle are not reported.
"""
    (args.output_dir / "REPORT.md").write_text(report)


if __name__ == "__main__":
    main()

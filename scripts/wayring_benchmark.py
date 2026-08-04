#!/usr/bin/env python3
"""Reproducible core-Wayland server benchmark. Run via `zig build benchmark-wayring`."""
import argparse, csv, json, os, platform, signal, stat, statistics, subprocess, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out" / "wayring-benchmark"

def wait_for(predicate, timeout, description):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.01)
    raise TimeoutError(f"timed out waiting for {description}")

def snapshot(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    status = {}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if ":" in line: status[line.split(":", 1)[0]] = line.split(":", 1)[1].strip()
    kb = lambda key: int(status.get(key, "0 kB").split()[0])
    return dict(ticks=int(fields[13])+int(fields[14]), minflt=int(fields[9]), majflt=int(fields[11]),
                voluntary=int(status.get("voluntary_ctxt_switches", 0)),
                involuntary=int(status.get("nonvoluntary_ctxt_switches", 0)), rss_kb=kb("VmRSS"), hwm_kb=kb("VmHWM"))

def stop(proc):
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try: proc.wait(5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL); proc.wait(5)

def start_server(name, base, prefix=()):
    runtime = base / "runtime"; runtime.mkdir(mode=0o700)
    env = os.environ.copy(); socket = base / "wayland.sock"
    if name == "wayring":
        command = [*prefix, str(BIN/"wayring-example"), str(socket)]
    else:
        config = base / "sway.conf"
        config.write_text("xwayland disable\nseat seat0 fallback true\n")
        env.update(XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1")
        command = [*prefix, "sway", "--unsupported-gpu", "-c", str(config)]
    log = open(base/"server.log", "w")
    proc = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    if name == "sway":
        def find_socket():
            candidates = [path for path in runtime.glob("wayland-*") if stat.S_ISSOCK(path.stat().st_mode)]
            return candidates[0] if candidates else None
        socket = wait_for(find_socket, 10, "Sway Wayland socket")
    else: wait_for(lambda: socket.exists() and socket, 10, "Wayring socket")
    return proc, socket, command, env, log

def measured(name, workload, operations, warmup, repetition):
    with tempfile.TemporaryDirectory(prefix="wayring-bench-") as td:
        proc, socket, command, env, log = start_server(name, Path(td))
        try:
            client = subprocess.Popen([str(BIN/"wayring-benchmark-client"), str(socket), workload,
                                       str(operations), str(warmup), "500"], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                      start_new_session=True)
            if wait_for(lambda: client.stdout.readline(), 15, "client warmup") != "READY\n": raise RuntimeError("client did not become ready")
            before = snapshot(proc.pid); client.stdin.write("x"); client.stdin.flush()
            result = json.loads(wait_for(lambda: client.stdout.readline(), 60, "client result")); after = snapshot(proc.pid)
            client.wait(5)
            if client.returncode: raise RuntimeError(client.stderr.read())
            if name == "wayring": proc.wait(10)
            tick_ns = 1_000_000_000 // os.sysconf("SC_CLK_TCK")
            row = dict(server=name, repetition=repetition, **result)
            row.update(server_cpu_ns=(after["ticks"]-before["ticks"])*tick_ns,
                       cpu_ns_per_op=(after["ticks"]-before["ticks"])*tick_ns/operations,
                       voluntary_ctxt=after["voluntary"]-before["voluntary"], involuntary_ctxt=after["involuntary"]-before["involuntary"],
                       minor_faults=after["minflt"]-before["minflt"], major_faults=after["majflt"]-before["majflt"],
                       rss_kb=after["rss_kb"], hwm_kb=after["hwm_kb"])
            return row, command
        finally: stop(proc); log.close()

def profile_strace(name, out, workload, operations, warmup):
    with tempfile.TemporaryDirectory(prefix="wayring-strace-") as td:
        summary = out/f"strace-{name}-{workload}.txt"
        prefix = ["strace", "-f", "-c", "-o", str(summary)]
        proc, socket, command, env, log = start_server(name, Path(td), prefix)
        try:
            client = subprocess.run([str(BIN/"wayring-benchmark-client"), str(socket), workload, str(operations), str(warmup), "50"],
                                    input="x", text=True, capture_output=True, timeout=90, check=True)
            if name == "wayring": proc.wait(15)
        finally: stop(proc); log.close()
        return command

def profile_perf(name, out, workload, operations, warmup):
    with tempfile.TemporaryDirectory(prefix="wayring-perf-") as td:
        proc, socket, command, env, log = start_server(name, Path(td))
        summary = out/f"perf-{name}-{workload}.csv"
        client = None
        perf = None
        try:
            client = subprocess.Popen([str(BIN/"wayring-benchmark-client"), str(socket), workload,
                                       str(operations), str(warmup), "500"], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                      start_new_session=True)
            if wait_for(lambda: client.stdout.readline(), 15, "perf client warmup") != "READY\n": raise RuntimeError("perf client did not become ready")
            perf_command = ["perf", "stat", "-x,", "-o", str(summary), "-e",
                            "task-clock,cycles,instructions,context-switches,page-faults", "-p", str(proc.pid)]
            perf = subprocess.Popen(perf_command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                    text=True, start_new_session=True)
            time.sleep(.1)
            client.stdin.write("x"); client.stdin.flush()
            json.loads(wait_for(lambda: client.stdout.readline(), 90, "perf client result"))
            perf.send_signal(signal.SIGINT)
            perf.wait(10)
            client.wait(5)
            if client.returncode: raise RuntimeError(client.stderr.read())
            if name == "wayring": proc.wait(10)
            return perf_command
        finally:
            if perf is not None: stop(perf)
            if client is not None: stop(client)
            stop(proc); log.close()

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", default=str(ROOT/".amp/in/artifacts/wayring-benchmark")); ap.add_argument("--repetitions", type=int, default=5)
    ap.add_argument("--serial", type=int, default=30000); ap.add_argument("--pipeline", type=int, default=100000); ap.add_argument("--warmup", type=int, default=100)
    ap.add_argument("--skip-strace", action="store_true"); ap.add_argument("--skip-perf", action="store_true"); args = ap.parse_args()
    out=Path(args.output); out.mkdir(parents=True, exist_ok=True)
    rows=[]; commands=[]
    for name in ("wayring", "sway"):
        for workload, operations in (("serial", args.serial), ("pipeline", args.pipeline)):
            for repetition in range(1,args.repetitions+1):
                row, command=measured(name,workload,operations,args.warmup,repetition); rows.append(row); commands.append(command); print(row)
    with open(out/"raw.csv","w",newline="") as f:
        writer=csv.DictWriter(f,fieldnames=rows[0]); writer.writeheader(); writer.writerows(rows)
    metadata=dict(timestamp=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()), kernel=platform.release(),
                  sway=subprocess.check_output(["sway","--version"],text=True).strip(), zig=subprocess.check_output(["zig","version"],text=True).strip(),
                  repetitions=args.repetitions, serial_operations=args.serial, pipeline_operations=args.pipeline, warmup_roundtrips=args.warmup,
                  commands=commands, sway_config="xwayland disable\\nseat seat0 fallback true",
                  environment={"WLR_BACKENDS":"headless","WLR_RENDERER":"pixman","WLR_LIBINPUT_NO_DEVICES":"1"})
    if not args.skip_strace:
        for name in ("wayring","sway"): metadata.setdefault("strace_commands",[]).append(profile_strace(name,out,"pipeline",args.pipeline,args.warmup))
    if not args.skip_perf:
        for name in ("wayring","sway"): metadata.setdefault("perf_commands",[]).append(profile_perf(name,out,"pipeline",args.pipeline,args.warmup))
    (out/"raw.json").write_text(json.dumps(dict(metadata=metadata,samples=rows),indent=2)+"\n")
    report=["# Wayring vs headless Sway core-Wayland benchmark","",f"Kernel `{metadata['kernel']}`; `{metadata['sway']}`; Zig `{metadata['zig']}`. {args.repetitions} samples per cell after {args.warmup} warm-up roundtrips.","",
            "| server | workload | operations | wall ns/op median (min–max) | server CPU ns/op median (min–max) | RSS/HWM KiB median |","|---|---:|---:|---:|---:|---:|"]
    for name in ("wayring","sway"):
      for workload in ("serial","pipeline"):
        group=[r for r in rows if r["server"]==name and r["workload"]==workload]; wall=[r["wall_ns"]/r["operations"] for r in group]; cpu=[r["cpu_ns_per_op"] for r in group]
        report.append(f"| {name} | {workload} | {group[0]['operations']} | {statistics.median(wall):.1f} ({min(wall):.1f}–{max(wall):.1f}) | {statistics.median(cpu):.1f} ({min(cpu):.1f}–{max(cpu):.1f}) | {statistics.median(r['rss_kb'] for r in group):.0f}/{statistics.median(r['hwm_kb'] for r in group):.0f} |")
    report += ["","CPU is server-only `/proc/PID/stat` user+system ticks bracketed by the measured client section; tick quantization applies. Context switches and faults are in `raw.csv`.",
               "Sway is a complete headless compositor while Wayring is a minimal once-only protocol example, so this measures total-server overhead, not isolated libwayland parity.",
               "Syscall profiles are separate `strace -f -c` runs. Wayring submits accept/recvmsg/sendmsg through io_uring, so its visible process syscalls are chiefly `io_uring_setup`/`io_uring_enter`; compare summaries with that semantic difference in mind.",
               "Perf profiles are separate attached runs. This orb exposes software counters, but hardware cycles/instructions may be reported as unsupported; no unavailable counters are inferred.","","Exact commands, environment, config, versions, and samples are in `raw.json`."]
    (out/"REPORT.md").write_text("\n".join(report)+"\n")

if __name__=="__main__": main()

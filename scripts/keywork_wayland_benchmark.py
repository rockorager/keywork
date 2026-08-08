#!/usr/bin/env python3
"""P3-H Wave 0 same-binary Keywork Wayland-server parity harness (no claims)."""
import argparse, csv, json, os, platform, random, select, signal, socket, subprocess, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def proc(pid):
    stat = Path(f"/proc/{pid}/stat").read_text().split()
    status = dict(line.split(":", 1) for line in Path(f"/proc/{pid}/status").read_text().splitlines() if ":" in line)
    number = lambda key: int(status.get(key, " 0").strip().split()[0])
    return {"user_ticks": int(stat[13]), "system_ticks": int(stat[14]), "minor_faults": int(stat[9]), "major_faults": int(stat[11]),
            "rss_kb": number("VmRSS"), "hwm_kb": number("VmHWM"), "voluntary_ctxt": number("voluntary_ctxt_switches"),
            "involuntary_ctxt": number("nonvoluntary_ctxt_switches"), "fds": len(list(Path(f"/proc/{pid}/fd").iterdir()))}

def wait_socket(runtime, process, timeout):
    started = time.monotonic_ns(); deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None: raise RuntimeError(f"compositor exited {process.returncode} before becoming connectable")
        for path in runtime.glob("wayland-*"):
            try:
                probe=socket.socket(socket.AF_UNIX); probe.connect(str(path)); probe.close()
                return path, time.monotonic_ns()-started
            except OSError: pass
        time.sleep(.005)
    raise TimeoutError("compositor did not become connectable")

def wait_display_name(process, timeout):
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready: raise TimeoutError("compositor did not emit its canonical display name")
    line = process.stdout.readline().strip()
    if not line.startswith("WAYLAND_DISPLAY="):
        raise RuntimeError(f"unexpected first compositor output: {line!r}")
    return line.split("=", 1)[1]

def read_line_before(stream, process, deadline, description):
    timeout=deadline-time.monotonic()
    if timeout <= 0 or not select.select([stream], [], [], timeout)[0]:
        raise TimeoutError(f"timed out waiting for {description}")
    line=stream.readline()
    if not line:
        raise RuntimeError(f"process {process.pid} exited while waiting for {description}")
    return line

def connect_socket(path):
    probe=socket.socket(socket.AF_UNIX)
    try: probe.connect(str(path))
    finally: probe.close()

def public_sockets(runtime):
    return sorted(path for path in runtime.glob("wayland-[0-9]*") if path.is_socket())

def lifecycle_check(args):
    checks=[]
    with tempfile.TemporaryDirectory(prefix="keywork-parity-lifecycle-") as td:
        runtime=Path(td)/"runtime"; runtime.mkdir(mode=0o700)
        cases=(("wayring", ["--wayland-server", "wayring"], 1),
               ("libwayland", ["--wayland-server", "libwayland"], 1),
               ("wayring", ["--wayland-server", "wayring"], 1),
               ("dual", ["--wayland-server", "dual"], 2),
               ("deprecated-alias", ["--experimental-wayring"], 2))
        for label, selector_args, expected_sockets in cases:
            if public_sockets(runtime) or list(runtime.glob("wayland-[0-9]*.lock")):
                raise RuntimeError(f"public Wayland paths survived before {label}")
            env=os.environ.copy(); env.update(XDG_RUNTIME_DIR=str(runtime), KEYWORK_WAYRING_DISPLAY="stale-parent-value")
            command=[str(args.compositor), "--output", "headless", *selector_args]
            log=open(Path(td)/f"{label}.log","w")
            server=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=log,text=True,start_new_session=True)
            try:
                _,_=wait_socket(runtime,server,args.timeout); canonical=wait_display_name(server,args.timeout); path=runtime/canonical
                connect_socket(path)
                sockets=public_sockets(runtime)
                if canonical != path.name or len(sockets) != expected_sockets:
                    raise RuntimeError(f"{label}: canonical={canonical!r}, public sockets={[p.name for p in sockets]}")
                client=subprocess.run([str(args.client),str(path),"registry","1","1","1"],input="x",text=True,capture_output=True,timeout=args.timeout)
                if client.returncode or not client.stdout.startswith("READY\n"):
                    raise RuntimeError(f"{label}: external registry client failed: {client.stderr}")
                os.killpg(server.pid,signal.SIGTERM); server.wait(args.timeout)
                remaining=server.stdout.read().splitlines(); output=[f"WAYLAND_DISPLAY={canonical}",*remaining]
                sidecars=[line for line in output if line.startswith("KEYWORK_WAYRING_DISPLAY=")]
                if (label in ("dual", "deprecated-alias")) != (len(sidecars) == 1):
                    raise RuntimeError(f"{label}: unexpected output lines {output!r}")
                if sidecars:
                    sidecar=sidecars[0].split("=",1)[1]
                    if sidecar == canonical or sidecar not in {socket_path.name for socket_path in sockets}:
                        raise RuntimeError(f"{label}: invalid sidecar display {sidecar!r}")
                checks.append({"case":label,"command":command,"canonical_display":canonical,
                               "public_sockets":[p.name for p in sockets],"stdout":output})
            finally:
                if server.poll() is None: os.killpg(server.pid,signal.SIGKILL); server.wait()
                server.stdout.close(); log.close()
            leftovers=[p.name for p in runtime.glob("wayland-[0-9]*")]
            if leftovers:
                raise RuntimeError(f"{label}: owned Wayland paths survived teardown: {leftovers}")
    return checks

def run_sample(args, selector, workload, repetition, pair, position):
    with tempfile.TemporaryDirectory(prefix="keywork-parity-") as td:
        base=Path(td); runtime=base/"runtime"; runtime.mkdir(mode=0o700)
        env=os.environ.copy(); env["XDG_RUNTIME_DIR"]=str(runtime)
        command=[str(args.compositor), "--output", "headless", "--wayland-server", selector]
        log=open(base/"compositor.log", "w")
        parent_fds_before=len(list(Path("/proc/self/fd").iterdir()))
        begin=time.monotonic_ns(); server=subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=log, text=True, start_new_session=True)
        clients=[]
        try:
            path, connectable_ns=wait_socket(runtime,server,args.timeout)
            canonical_display=wait_display_name(server,args.timeout)
            startup_ready_ns=time.monotonic_ns()-begin
            if canonical_display != path.name:
                raise RuntimeError(f"emitted {canonical_display!r}, connected to {path.name!r}")
            time.sleep(args.idle_ms/1000); before=proc(server.pid)
            quotient,remainder=divmod(args.operations,args.concurrency)
            client_commands=[]
            for index in range(args.concurrency):
                count=quotient+(1 if index < remainder else 0)
                client_command=[str(args.client), str(path), workload, str(count), str(args.warmup), "1"]
                client_commands.append(client_command)
                clients.append(subprocess.Popen(client_command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True))
            ready_deadline=time.monotonic()+args.timeout
            for client in clients:
                if read_line_before(client.stdout,client,ready_deadline,"client readiness") != "READY\n":
                    raise RuntimeError("client emitted an invalid readiness line")
            wall=time.monotonic_ns()
            for client in clients: client.stdin.write("x"); client.stdin.flush()
            result_deadline=time.monotonic()+args.timeout
            results=[json.loads(read_line_before(client.stdout,client,result_deadline,"client result")) for client in clients]
            wall_ns=time.monotonic_ns()-wall
            completion_deadline=time.monotonic()+args.timeout
            for client in clients:
                client.wait(max(0,completion_deadline-time.monotonic()))
                if client.returncode: raise RuntimeError(client.stderr.read())
                client.stdin.close(); client.stdout.close(); client.stderr.close()
            after=proc(server.pid)
            os.killpg(server.pid,signal.SIGTERM); teardown=time.monotonic_ns(); server.wait(args.timeout); teardown_ns=time.monotonic_ns()-teardown
            tick_ns=1_000_000_000//os.sysconf("SC_CLK_TCK")
            runtime_entries_after_teardown=len(list(runtime.iterdir()))
            server.stdout.close()
            parent_fds_after=len(list(Path("/proc/self/fd").iterdir()))
            row={"selector":selector,"mode":selector,"workload":workload,"repetition":repetition,"pair":pair,"order_position":position,
                 "concurrency":args.concurrency,"operations":sum(x["operations"] for x in results),"wall_ns":wall_ns,
                 "throughput_ops_s":sum(x["operations"] for x in results)*1e9/wall_ns,"startup_connectable_ns":connectable_ns,
                 "startup_ready_ns":startup_ready_ns,"canonical_display":canonical_display,"idle_ms":args.idle_ms,"teardown_ns":teardown_ns,
                 "runtime_entries_after_teardown":runtime_entries_after_teardown,"fd_idle":before["fds"],"fd_after":after["fds"],
                 "parent_fd_before":parent_fds_before,"parent_fd_after":parent_fds_after,
                 "cpu_user_ns":(after["user_ticks"]-before["user_ticks"])*tick_ns,
                 "cpu_system_ns":(after["system_ticks"]-before["system_ticks"])*tick_ns,"rss_kb":after["rss_kb"],"hwm_kb":after["hwm_kb"]}
            for key in ("minor_faults","major_faults","voluntary_ctxt","involuntary_ctxt"): row[key]=after[key]-before[key]
            return row, command, client_commands
        finally:
            for client in clients:
                if client.poll() is None: os.killpg(client.pid,signal.SIGKILL)
            for client in clients:
                try: client.wait(5)
                except subprocess.TimeoutExpired: pass
                for stream in (client.stdin,client.stdout,client.stderr):
                    if stream is not None and not stream.closed: stream.close()
            if server.poll() is None: os.killpg(server.pid,signal.SIGKILL); server.wait()
            if server.stdout is not None and not server.stdout.closed: server.stdout.close()
            log.close()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--compositor",type=Path,default=ROOT/"zig-out/bin/keywork-compositor"); p.add_argument("--client",type=Path,default=ROOT/"zig-out/wayring-benchmark/wayring-benchmark-client")
    p.add_argument("--output-dir",type=Path,default=ROOT/".amp/in/artifacts/keywork-wayland-parity"); p.add_argument("--repetitions",type=int,default=5)
    p.add_argument("--operations",type=int,default=1000); p.add_argument("--warmup",type=int,default=10); p.add_argument("--concurrency",type=int,default=1)
    p.add_argument("--workloads",nargs="+",choices=("serial","pipeline","registry","churn"),default=("serial","pipeline","registry","churn"))
    p.add_argument("--seed",type=int,default=1); p.add_argument("--idle-ms",type=int,default=100); p.add_argument("--timeout",type=float,default=30)
    p.add_argument("--dedicated-machine",choices=("yes","no","unknown"),default="unknown")
    a=p.parse_args()
    if a.operations < 1 or a.concurrency < 1 or a.concurrency > a.operations: p.error("require operations >= concurrency >= 1")
    a.output_dir.mkdir(parents=True,exist_ok=True); lifecycle=lifecycle_check(a); rng=random.Random(a.seed); rows=[]; commands=[]
    for workload in a.workloads:
        for rep in range(1,a.repetitions+1):
            order=["libwayland","wayring"]; rng.shuffle(order)
            for position,selector in enumerate(order,1):
                row,server_cmd,client_cmd=run_sample(a,selector,workload,rep,f"{workload}-{rep}",position); rows.append(row); commands.append({"server":server_cmd,"client":client_cmd})
                print(json.dumps(row))
    with open(a.output_dir/"raw.csv","w",newline="") as f: writer=csv.DictWriter(f,fieldnames=rows[0]); writer.writeheader(); writer.writerows(rows)
    version=subprocess.run([str(a.compositor),"--version"],text=True,capture_output=True)
    git_commit=subprocess.run(["git","rev-parse","HEAD"],cwd=ROOT,text=True,capture_output=True).stdout.strip()
    git_tree=subprocess.run(["git","rev-parse","HEAD^{tree}"],cwd=ROOT,text=True,capture_output=True).stdout.strip()
    git_dirty=bool(subprocess.run(["git","status","--porcelain"],cwd=ROOT,text=True,capture_output=True).stdout)
    metadata={"purpose":"same ReleaseSafe Keywork binary/config selector harness; no comparative claim","timestamp":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),
      "selectors":["libwayland","wayring"],"fixed_arguments":["--output","headless"],"no_sidecar":True,"repetitions":a.repetitions,"random_seed":a.seed,
      "order":"randomized AB/BA per workload/repetition","requested_operations":a.operations,"warmup":a.warmup,"concurrency":a.concurrency,"dedicated_machine":a.dedicated_machine,
      "kernel":platform.release(),"platform":platform.platform(),"machine":platform.machine(),"cpu_count":os.cpu_count(),
      "python":platform.python_version(),"zig":subprocess.check_output(["zig","version"],text=True).strip(),
      "compositor_version":(version.stdout+version.stderr).strip(),"git_commit":git_commit,"git_tree":git_tree,"git_worktree_dirty":git_dirty,"commands":commands,
      "lifecycle_check":lifecycle,
      "environment":{"XDG_RUNTIME_DIR":"per-sample private temporary directory"},
      "unavailable_counters":["hardware performance counters"],"unimplemented_workloads":["basic SHM/XDG lifecycle (production fixture exposes no generated xdg-shell client API)"]}
    (a.output_dir/"raw.json").write_text(json.dumps({"metadata":metadata,"samples":rows},indent=2)+"\n")
    (a.output_dir/"REPORT.md").write_text("# P3-H Wave 0 raw parity harness\n\nNo comparative claim is made. See `raw.csv` and `raw.json`. Both selectors use the exact same ReleaseSafe Keywork compositor artifact and headless configuration, without a sidecar. Hardware counters and SHM/XDG lifecycle are not reported.\n")

if __name__ == "__main__": main()

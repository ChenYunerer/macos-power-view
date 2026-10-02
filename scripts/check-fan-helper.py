"""Exercise the real helper protocol in simulation; never writes hardware."""
import pathlib
import subprocess
import sys
import signal
import time

binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/PowerFanHelper").resolve()


def session(timeout="20"):
    process = subprocess.Popen([str(binary), "--simulate", timeout], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert process.stdout.readline().strip() == "SIMULATED READY"
    return process


def command(process, value):
    process.stdin.write(value + "\n")
    process.stdin.flush()
    return process.stdout.readline().strip()


p = session()
for value in ["0", "1198", "7200", "nan", "inf", "3000.5", "3000 trailing", ""]:
    assert command(p, "SET 0 " + value) == "ERR 3 0 0", value
assert command(p, "unrecognized") == "ERR 7 0 0"
for value in ["1199", "3000", "7199"]:
    assert command(p, "SET 0 " + value) == "OK 1 1"
assert command(p, "PING") == "OK 1 1"
assert command(p, "AUTO") == "OK 0 0"
assert command(p, "QUIT") == "OK 0 0"
assert p.wait(timeout=3) == 0

p = session("0.4")
assert command(p, "SET 0 3000") == "OK 1 1"
assert command(p, "SET 1 4200") == "OK 3 1"
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT 3"
assert p.wait(timeout=3) == 0

p = session()
assert command(p, "SET 0 3000") == "OK 1 1"
assert command(p, "SET 1 4200") == "OK 3 1"
p.stdin.close()
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT 3"
assert p.wait(timeout=3) == 0

p = session()
assert command(p, "SET 0 3000") == "OK 1 1"
assert command(p, "SET 1 4200") == "OK 3 1"
p.terminate()
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT 3"
assert p.wait(timeout=3) == 0
print("Passed helper simulation: bounds, protocol, auto, disconnect, heartbeat expiry, termination.")

for payload in ["PING", "X" * 81, "PING\0"]:
    p = session("0.4")
    assert command(p, "SET 0 3000") == "OK 1 1"
    assert command(p, "SET 1 4200") == "OK 3 1"
    p.stdin.write(payload)
    p.stdin.flush()
    assert p.stdout.readline().strip() == "RESTORED_ON_EXIT 3"
    assert p.wait(timeout=3) == 0

p = session("0.4")
assert command(p, "SET 0 3000") == "OK 1 1"
assert command(p, "SET 1 4200") == "OK 3 1"
p.send_signal(signal.SIGSTOP)
time.sleep(0.6)
p.stdin.write("PING\n")
p.stdin.flush()
p.send_signal(signal.SIGCONT)
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT 3"
assert p.wait(timeout=3) == 0
for invalid in ["nan", "inf", "0", "21"]:
    result = subprocess.run([str(binary), "--simulate", invalid], capture_output=True, timeout=3)
    assert result.returncode == 2, invalid
print("Passed malformed/partial input, suspended helper expiry, and invalid timeout checks.")

# Independent targets and ownership survive an invalid command or another fan's AUTO.
p = session()
for invalid in ["SET -1 3000", "SET 16 3000", "SET 2 3000", "SET 1 2000",
                "SET 0", "SET 0 3000 extra", "AUTO -1", "AUTO 16", "AUTO 1 extra"]:
    assert command(p, invalid) == "ERR 3 0 0", invalid
assert command(p, "SET 0 2000") == "OK 1 1"
assert command(p, "SET 1 4200") == "OK 3 1"
assert command(p, "SET 1 2000") == "ERR 3 3 1"
assert command(p, "AUTO 0") == "OK 2 1"
assert command(p, "PING") == "OK 2 1"
assert command(p, "AUTO 1") == "OK 0 0"
assert command(p, "QUIT") == "OK 0 0"
assert p.wait(timeout=3) == 0
print("Passed independent fan protocol: IDs, per-fan bounds, ownership, individual restore, and restore-all on exit.")

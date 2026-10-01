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
    assert command(p, "SET " + value) == "ERR 3", value
assert command(p, "unrecognized") == "ERR 7"
for value in ["1199", "3000", "7199"]:
    assert command(p, "SET " + value) == "OK"
assert command(p, "PING") == "OK"
assert command(p, "AUTO") == "OK"
assert command(p, "QUIT") == "OK"
assert p.wait(timeout=3) == 0

p = session("0.4")
assert command(p, "SET 3000") == "OK"
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT"
assert p.wait(timeout=3) == 0

p = session()
assert command(p, "SET 3000") == "OK"
p.stdin.close()
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT"
assert p.wait(timeout=3) == 0

p = session()
assert command(p, "SET 3000") == "OK"
p.terminate()
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT"
assert p.wait(timeout=3) == 0
print("Passed helper simulation: bounds, protocol, auto, disconnect, heartbeat expiry, termination.")

for payload in ["PING", "X" * 81, "PING\0"]:
    p = session("0.4")
    assert command(p, "SET 3000") == "OK"
    p.stdin.write(payload)
    p.stdin.flush()
    assert p.stdout.readline().strip() == "RESTORED_ON_EXIT"
    assert p.wait(timeout=3) == 0

p = session("0.4")
assert command(p, "SET 3000") == "OK"
p.send_signal(signal.SIGSTOP)
time.sleep(0.6)
p.stdin.write("PING\n")
p.stdin.flush()
p.send_signal(signal.SIGCONT)
assert p.stdout.readline().strip() == "RESTORED_ON_EXIT"
assert p.wait(timeout=3) == 0
for invalid in ["nan", "inf", "0", "21"]:
    result = subprocess.run([str(binary), "--simulate", invalid], capture_output=True, timeout=3)
    assert result.returncode == 2, invalid
print("Passed malformed/partial input, suspended helper expiry, and invalid timeout checks.")

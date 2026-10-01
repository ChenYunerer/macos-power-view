#!/usr/bin/env python3
"""查看 Mac 电源功率：./power.py 或 ./power.py --watch 2。"""

import argparse
from datetime import datetime
import math
import plistlib
import subprocess
import sys
import time


def refresh_interval(value):
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("刷新间隔必须是正数（秒）")
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("刷新间隔必须是有限的正数（秒）")
    return seconds


def read_battery():
    result = subprocess.run(
        ["/usr/sbin/ioreg", "-a", "-r", "-n", "AppleSmartBattery"],
        capture_output=True,
        check=True,
        timeout=10,
    )
    devices = plistlib.loads(result.stdout)
    if not devices:
        raise RuntimeError("没有找到 AppleSmartBattery，请在 Mac 笔记本上运行")
    return devices[0]


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def watts(value):
    return f"{value / 1000:.1f} W" if number(value) else "设备未提供"


def render(battery):
    telemetry = battery.get("PowerTelemetryData") or {}
    adapter = battery.get("AdapterDetails") or {}
    connected = battery.get("ExternalConnected", False)
    charging = battery.get("IsCharging", False)
    status = "正在充电" if charging else ("已接电源，未充电" if connected else "使用电池")
    capacity = battery.get("CurrentCapacity")
    capacity_text = f"{capacity}%" if number(capacity) else "未知"
    lines = [
        f"Mac 电源功率  {datetime.now():%Y-%m-%d %H:%M:%S}",
        f"电量：{capacity_text} · {status}",
        "",
    ]

    if connected:
        lines.append(f"电脑端输入功率：{watts(telemetry.get('SystemPowerIn'))}")
        voltage = telemetry.get("SystemVoltageIn")
        current = telemetry.get("SystemCurrentIn")
        if number(voltage) and number(current):
            lines.append(f"输入电压 / 电流：{voltage / 1000:.2f} V / {current / 1000:.3f} A")
        lines.append(f"系统耗电功率：  {watts(telemetry.get('SystemLoad'))}")
        lines.append(f"电池净充电功率：{watts(telemetry.get('BatteryPower'))}（负值表示放电）")
        limit = adapter.get("Watts")
        limit_text = f"{limit:g} W" if number(limit) else "设备未提供"
        lines.append(f"充电器协商功率：{limit_text}")
    else:
        # 拔掉电源后，适配器遥测可能保留旧值，不把旧值显示为实时输入。
        lines.append("电脑端输入功率：0.0 W（未连接外部电源）")
        current = battery.get("InstantAmperage", battery.get("Amperage"))
        voltage = battery.get("Voltage")
        if number(current) and number(voltage):
            if current >= 2**63:
                current -= 2**64
            lines.append(f"电池净放电功率：{-current * voltage / 1_000_000:.1f} W")

    lines.extend(["", "输入功率为电脑端读数；协商功率为供电上限。系统读数按自身周期更新。"])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="查看 Mac 当前输入功率、充电功率和电量，无需 sudo。",
        epilog="示例：./power.py   或   ./power.py --watch 2",
    )
    parser.add_argument(
        "-w", "--watch", nargs="?", const=2.0, type=refresh_interval,
        metavar="秒", help="持续刷新，默认每 2 秒一次；按 Ctrl+C 退出",
    )
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.exit(1, "错误：此脚本仅支持 macOS。\n")
    try:
        while True:
            output = render(read_battery())
            if args.watch is not None and sys.stdout.isatty():
                print("\033[2J\033[H", end="")
            print(output, flush=True)
            if args.watch is None:
                return 0
            print("\n持续刷新中，按 Ctrl+C 退出。", flush=True)
            time.sleep(args.watch)
    except KeyboardInterrupt:
        print("\n已停止。")
        return 0
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
        print(f"读取电源信息失败：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

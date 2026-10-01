#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
clang -I Sources/ThermalSensors/include Tests/FanSensorsTests.c \
    -framework IOKit -framework CoreFoundation -o .build/fan-sensor-checks
.build/fan-sensor-checks

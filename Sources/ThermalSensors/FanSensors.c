#include "ThermalSensors.h"
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key;
    Version version;
    Limits limits;
    KeyInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMCPacket;
_Static_assert(sizeof(SMCPacket) == 80, "Unexpected SMC packet layout");

static _Thread_local char diagnostic[176];
const char *PVFanControlDiagnostic(void) { return diagnostic; }

static uint32_t keyCode(const char *s) {
    return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16
        | (uint32_t)(uint8_t)s[2] << 8 | (uint8_t)s[3];
}

static int readCall(io_connect_t connection, SMCPacket *input, SMCPacket *output) {
    size_t size = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    int success = result == KERN_SUCCESS && size == sizeof(*output) && output->result == 0;
    if (!success && input->command == 6) {
        snprintf(diagnostic, sizeof(diagnostic), "%c%c%c%c io=0x%08x smc=0x%02x status=0x%02x size=%zu uid=%u/%u",
            input->key >> 24, input->key >> 16 & 255, input->key >> 8 & 255, input->key & 255,
            result, output->result, output->status, size, getuid(), geteuid());
    }
    return success;
}

static double readNumber(io_connect_t connection, const char *key) {
    SMCPacket input = {0}, info = {0}, output = {0};
    input.key = keyCode(key);
    input.command = 9; // Read key metadata.
    if (!readCall(connection, &input, &info) || info.info.size == 0 || info.info.size > 32) return NAN;
    input.info.size = info.info.size;
    input.command = 5; // Read bytes.
    if (!readCall(connection, &input, &output)) return NAN;
    if ((info.info.type == keyCode("ui8 ") || info.info.type == keyCode("flag")) && info.info.size == 1) return output.bytes[0];
    if (info.info.type == keyCode("flt ") && info.info.size == 4) {
        float value;
        memcpy(&value, output.bytes, 4);
        return value;
    }
    if (info.info.type == keyCode("fpe2") && info.info.size == 2)
        return ((uint16_t)output.bytes[0] * 256 + output.bytes[1]) / 4.0;
    return NAN;
}

double PVReadFanRPM(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NAN;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) return NAN;
    double count = readNumber(connection, "FNum"), fastest = NAN;
    if (isfinite(count) && count >= 1 && count <= 16 && floor(count) == count) {
        for (int i = 0; i < (int)count; i++) {
            char key[5];
            snprintf(key, sizeof(key), "F%XAc", i);
            double rpm = readNumber(connection, key);
            if (isfinite(rpm) && rpm >= 0 && rpm <= 50000)
                fastest = isnan(fastest) ? rpm : fmax(fastest, rpm);
        }
    }
    IOServiceClose(connection);
    return fastest;
}

static io_connect_t openSMC(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return IO_OBJECT_NULL;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : IO_OBJECT_NULL;
}

static const char *modeKey(io_connect_t connection) {
    return isfinite(readNumber(connection, "F0md")) ? "F0md" : "F0Md";
}

static PVFanStatus statusForConnection(io_connect_t connection) {
    PVFanStatus status = { NAN, NAN, NAN, NAN, 0, -1, 0 };
    double count = readNumber(connection, "FNum");
    if (!isfinite(count) || count < 1 || count > 16 || floor(count) != count) return status;
    status.count = (int)count;
    // Reuse this connection for monitoring and control metadata. On multi-fan
    // Macs the display still reports the fastest fan, while writes stay limited.
    for (int i = 0; i < status.count; i++) {
        char key[5];
        snprintf(key, sizeof(key), "F%XAc", i);
        double rpm = readNumber(connection, key);
        if (isfinite(rpm) && rpm >= 0 && rpm <= 50000)
            status.actual = isnan(status.actual) ? rpm : fmax(status.actual, rpm);
    }
    status.minimum = readNumber(connection, "F0Mn");
    status.maximum = readNumber(connection, "F0Mx");
    status.target = readNumber(connection, "F0Tg");
    double mode = readNumber(connection, modeKey(connection));
    if (mode == 0 || mode == 1 || mode == 3) status.mode = (int)mode;
#if defined(__aarch64__)
    // This controller is intentionally limited to the verified single-fan layout.
    status.controllable = status.count == 1 && status.mode >= 0 && isfinite(status.target)
        && isfinite(status.minimum) && isfinite(status.maximum)
        && status.minimum >= 500 && status.maximum <= 20000 && status.maximum > status.minimum;
#endif
    return status;
}

PVFanStatus PVReadFanStatus(void) {
    io_connect_t connection = openSMC();
    if (!connection) return (PVFanStatus){ NAN, NAN, NAN, NAN, 0, -1, 0 };
    PVFanStatus status = statusForConnection(connection);
    IOServiceClose(connection);
    return status;
}

static int writeNumber(io_connect_t connection, const char *key, double value) {
    // No arbitrary SMC key writes are exposed by this module.
    if (strcmp(key, "F0Md") && strcmp(key, "F0md") && strcmp(key, "F0Tg") && strcmp(key, "Ftst")) return 0;
    SMCPacket input = {0}, info = {0}, output = {0};
    input.key = keyCode(key);
    input.command = 9;
    if (!isfinite(value) || value < 0 || !readCall(connection, &input, &info)) return 0;
    input.info.size = info.info.size;
    input.command = 6;
    if ((info.info.type == keyCode("ui8 ") || info.info.type == keyCode("flag")) && info.info.size == 1 && value <= 1) {
        input.bytes[0] = (uint8_t)value;
    } else if (info.info.type == keyCode("flt ") && info.info.size == 4) {
        float number = (float)value;
        memcpy(input.bytes, &number, 4);
    } else if (info.info.type == keyCode("fpe2") && info.info.size == 2 && value <= 16383) {
        uint16_t number = (uint16_t)round(value * 4);
        input.bytes[0] = number >> 8;
        input.bytes[1] = number & 255;
    } else return 0;
    return readCall(connection, &input, &output);
}

static int unlockedThermalControl = 0;

static int matchesValue(const char *key, double actual, double expected) {
    if (!isfinite(actual)) return 0;
    // Firmware can immediately promote automatic mode 0 to system mode 3.
    if (expected == 0 && (!strcmp(key, "F0Md") || !strcmp(key, "F0md")) && actual == 3) return 1;
    return fabs(actual - expected) <= 0.5;
}

static int writeWithRetry(io_connect_t connection, const char *key, double value) {
    for (int attempt = 0; attempt < 10; attempt++) {
        int written = writeNumber(connection, key, value);
        // Some firmware applies a write despite an error reply. Readback is
        // authoritative, but never assume a successful reply applied the value.
        double actual = readNumber(connection, key);
        if (matchesValue(key, actual, value)) return 1;
        if (written) break;
        if (attempt < 9) usleep(50000);
    }
    // Allow asynchronous firmware state to settle before declaring rejection.
    for (int attempt = 0; attempt < 10; attempt++) {
        usleep(50000);
        double actual = readNumber(connection, key);
        if (matchesValue(key, actual, value)) return 1;
    }
    if (!diagnostic[0]) snprintf(diagnostic, sizeof(diagnostic), "%s readback=%.0f expected=%.0f", key, readNumber(connection, key), value);
    return 0;
}

int PVRestoreFanAutomatic(void) {
    diagnostic[0] = 0;
    if (geteuid() != 0) return 1;
    io_connect_t connection = openSMC();
    if (!connection) return 2;
    // Always attempt every restoration step, even if one write fails.
    int modeOK = writeWithRetry(connection, modeKey(connection), 0);
    // Never request a stopped fan if mode switching failed and manual control
    // is still active. In auto mode the system may immediately set its own RPM.
    if (modeOK) writeNumber(connection, "F0Tg", 0);
    int unlockOK = !unlockedThermalControl || writeWithRetry(connection, "Ftst", 0);
    if (unlockOK) unlockedThermalControl = 0;
    double mode = readNumber(connection, modeKey(connection));
    IOServiceClose(connection);
    return modeOK && unlockOK && (mode == 0 || mode == 3) ? 0 : 6;
}

int PVSetFanManual(double rpm) {
    diagnostic[0] = 0;
    if (geteuid() != 0) return 1;
    io_connect_t connection = openSMC();
    if (!connection) return 2;
    PVFanStatus status = statusForConnection(connection);
    if (!status.controllable || !isfinite(rpm) || rpm < status.minimum || rpm > status.maximum || floor(rpm) != rpm) {
        IOServiceClose(connection);
        return 3;
    }
    int enabled = writeWithRetry(connection, modeKey(connection), 1);
    if (!enabled && isfinite(readNumber(connection, "Ftst"))) {
        // Some Apple Silicon firmware requires thermalmonitord to yield first.
        if (writeNumber(connection, "Ftst", 1)) {
            unlockedThermalControl = 1;
            usleep(3000000);
            for (int attempt = 0; attempt < 20 && !enabled; attempt++) {
                enabled = writeNumber(connection, modeKey(connection), 1);
                if (!enabled) usleep(100000);
            }
        }
    }
    if (enabled) diagnostic[0] = 0;
    int speedOK = enabled && writeWithRetry(connection, "F0Tg", rpm);
    double mode = readNumber(connection, modeKey(connection));
    double target = readNumber(connection, "F0Tg");
    IOServiceClose(connection);
    if (speedOK && mode == 1 && isfinite(target) && fabs(target - rpm) <= 1) {
        diagnostic[0] = 0;
        return 0;
    }
    if (!diagnostic[0]) snprintf(diagnostic, sizeof(diagnostic), "readback mode=%.0f target=%.0f expected=%.0f", mode, target, rpm);
    char failure[sizeof(diagnostic)];
    memcpy(failure, diagnostic, sizeof(failure));
    int restored = PVRestoreFanAutomatic();
    if (!restored) memcpy(diagnostic, failure, sizeof(diagnostic));
    return restored == 0 ? 4 : 6;
}

#include "ThermalSensors.h"
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include <time.h>

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

static double readNumberMatchingType(io_connect_t connection, const char *key, uint32_t expectedType) {
    SMCPacket input = {0}, info = {0}, output = {0};
    input.key = keyCode(key);
    input.command = 9; // Read key metadata.
    if (!readCall(connection, &input, &info) || info.info.size == 0 || info.info.size > 32) return NAN;
    if (expectedType && info.info.type != expectedType) return NAN;
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

static double readNumber(io_connect_t connection, const char *key) {
    return readNumberMatchingType(connection, key, 0);
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

static double hottestTemperature(io_connect_t connection, const char *const *keys, size_t count) {
    double hottest = NAN;
    for (size_t i = 0; i < count; i++) {
        double value = readNumberMatchingType(connection, keys[i], keyCode("flt "));
        if (isfinite(value) && value > 0 && value <= 125)
            hottest = isnan(hottest) ? value : fmax(hottest, value);
    }
    return hottest;
}

PVProcessorTemperatures PVReadSMCProcessorTemperatures(void) {
    PVProcessorTemperatures temperatures = { NAN, NAN };
    char chip[64] = {0};
    size_t size = sizeof(chip);
    if (sysctlbyname("machdep.cpu.brand_string", chip, &size, NULL, 0) != 0
        || size == 0 || size > sizeof(chip) || chip[size - 1] != '\0'
        || strcmp(chip, "Apple M4 Pro") != 0) return temperatures;

    // CPU/GPU HID events are absent on the verified M4 Pro. These SMC keys
    // are verified on Mac16,8; do not apply them to unrelated chip layouts.
    // Mapping: https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
    // M4 Pro-specific CPU keys: https://github.com/exelban/stats/issues/3270
    static const char *const cpuKeys[] = {
        "Te05", "Te0S", "Te06", "Te0T", "Tp01", "Tp05",
        "Tp09", "Tp0D", "Tp0H", "Tp0Y", "Tp0b", "Tp0e"
    };
    static const char *const gpuKeys[] = {
        "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"
    };
    io_connect_t connection = openSMC();
    if (!connection) return temperatures;
    temperatures.cpu = hottestTemperature(connection, cpuKeys, sizeof(cpuKeys) / sizeof(cpuKeys[0]));
    temperatures.gpu = hottestTemperature(connection, gpuKeys, sizeof(gpuKeys) / sizeof(gpuKeys[0]));
    IOServiceClose(connection);
    return temperatures;
}

static unsigned int controlledFans;
static int unlockedThermalControl;
static char ownedModeKeys[PV_MAX_FANS][5];
unsigned int PVFanControlMask(void) { return controlledFans; }
int PVFanControlIsActive(void) { return controlledFans != 0 || unlockedThermalControl; }

static int fanCountForConnection(io_connect_t connection) {
    double count = readNumber(connection, "FNum");
    return isfinite(count) && count >= 1 && count <= PV_MAX_FANS && floor(count) == count ? (int)count : 0;
}

static void fanKey(char key[5], int fan, const char *suffix) {
    snprintf(key, 5, "F%X%s", fan, suffix);
}

static double fanNumber(io_connect_t connection, int fan, const char *suffix) {
    char key[5];
    fanKey(key, fan, suffix);
    return readNumber(connection, key);
}

static double readMode(io_connect_t connection, int fan, char key[5]) {
    fanKey(key, fan, "md");
    double mode = readNumber(connection, key);
    if (!isfinite(mode)) {
        fanKey(key, fan, "Md");
        mode = readNumber(connection, key);
    }
    return mode;
}

static void readFanName(io_connect_t connection, int fan, char name[32]) {
    char key[5]; fanKey(key, fan, "ID");
    SMCPacket input = {0}, info = {0}, output = {0};
    input.key = keyCode(key);
    input.command = 9;
    if (!readCall(connection, &input, &info) || info.info.size == 0 || info.info.size > 32) return;
    size_t offset;
    if (info.info.type == keyCode("{fds") && info.info.size > 4) offset = 4;
    else if (info.info.type == keyCode("ch8*")) offset = 0;
    else return;
    input.info.size = info.info.size;
    input.command = 5;
    if (!readCall(connection, &input, &output)) return;
    size_t length = info.info.size - offset;
    if (length > 31) length = 31;
    for (size_t i = 0; i < length && output.bytes[offset + i]; i++) {
        unsigned char c = output.bytes[offset + i];
        if (c < 32 || c == 127) { name[0] = 0; return; }
        name[i] = c;
    }
}

static PVFanStatus statusForFan(io_connect_t connection, int fan) {
    PVFanStatus status = { NAN, NAN, NAN, NAN, fan, -1, 0 };
    readFanName(connection, fan, status.name);
    status.actual = fanNumber(connection, fan, "Ac");
    if (!isfinite(status.actual) || status.actual < 0 || status.actual > 50000) status.actual = NAN;
    status.minimum = fanNumber(connection, fan, "Mn");
    status.maximum = fanNumber(connection, fan, "Mx");
    status.target = fanNumber(connection, fan, "Tg");
    char key[5];
    double mode = readMode(connection, fan, key);
    if (mode == 0 || mode == 1 || mode == 3) status.mode = (int)mode;
#if defined(__aarch64__)
    status.controllable = status.mode >= 0 && isfinite(status.target) && status.target >= 0
        && isfinite(status.minimum) && isfinite(status.maximum)
        && status.minimum >= 500 && status.maximum <= 20000 && status.maximum > status.minimum;
#endif
    return status;
}

int PVReadFanStatuses(PVFanStatus *statuses, int capacity) {
    if (!statuses || capacity < 1) return 0;
    io_connect_t connection = openSMC();
    if (!connection) return 0;
    int count = fanCountForConnection(connection);
    if (count > capacity) count = 0;
    for (int i = 0; i < count; i++) statuses[i] = statusForFan(connection, i);
    IOServiceClose(connection);
    return count;
}

static int isModeKey(const char *key) {
    return !strcmp(key + 2, "Md") || !strcmp(key + 2, "md");
}

static int writeNumber(io_connect_t connection, const char *key, double value) {
    // Only this helper's owned fan modes/targets and the thermal-control flag.
    if (strlen(key) != 4) return 0;
    if (strcmp(key, "Ftst")) {
        static const char digits[] = "0123456789ABCDEF";
        const char *digit = strchr(digits, key[1]);
        if (key[0] != 'F' || !digit || (!isModeKey(key) && strcmp(key + 2, "Tg"))) return 0;
        int fan = (int)(digit - digits);
        if (!(controlledFans & (1u << fan))) return 0;
    }
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

static int matchesValue(const char *key, double actual, double expected) {
    if (!isfinite(actual)) return 0;
    // Firmware can immediately promote automatic mode 0 to system mode 3.
    if (expected == 0 && isModeKey(key) && actual == 3) return 1;
    return fabs(actual - expected) <= 0.5;
}

static uint64_t controlDeadline(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 4000000000ULL;
}

static int canChangeThermalControl(io_connect_t connection) {
    int count = fanCountForConnection(connection);
    if (!count) {
        snprintf(diagnostic, sizeof(diagnostic), "Ftst: fan enumeration unavailable");
        return 0;
    }
    for (int i = 0; i < count; i++) {
        if (controlledFans & (1u << i)) continue;
        char key[5];
        double mode = readMode(connection, i, key);
        if (mode != 0 && mode != 3) {
            snprintf(diagnostic, sizeof(diagnostic), "Ftst: %s mode=%.0f is not owned by this session", key, mode);
            return 0;
        }
    }
    return 1;
}

static int writeWithRetry(io_connect_t connection, const char *key, double value, uint64_t deadline) {
    diagnostic[0] = 0;
    // Every fan gets at least one restoration attempt, even if earlier fans
    // exhausted the shared retry budget. Total retries do not scale with count.
    for (int attempt = 0; attempt < 10; attempt++) {
        int written = writeNumber(connection, key, value);
        double actual = readNumber(connection, key);
        if (matchesValue(key, actual, value)) { diagnostic[0] = 0; return 1; }
        if (written || clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) >= deadline) break;
        if (attempt < 9) usleep(50000);
    }
    for (int attempt = 0; attempt < 10 && clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < deadline; attempt++) {
        usleep(50000);
        double actual = readNumber(connection, key);
        if (matchesValue(key, actual, value)) { diagnostic[0] = 0; return 1; }
    }
    if (!diagnostic[0]) snprintf(diagnostic, sizeof(diagnostic), "%s readback=%.0f expected=%.0f", key, readNumber(connection, key), value);
    return 0;
}

int PVRestoreFanAutomatic(int fan) {
    diagnostic[0] = 0;
    if (geteuid() != 0) return 1;
    if (fan < -1 || fan >= PV_MAX_FANS) return 3;
    unsigned int restoring = controlledFans & (fan < 0 ? 0xffffu : (1u << fan));
    if (!restoring && !unlockedThermalControl) return 0;
    io_connect_t connection = openSMC();
    if (!connection) return 2;
    uint64_t deadline = controlDeadline();
    char firstFailure[sizeof(diagnostic)] = {0};
    for (int i = 0; i < PV_MAX_FANS; i++) {
        if (!(restoring & (1u << i))) continue;
        int modeOK = writeWithRetry(connection, ownedModeKeys[i], 0, deadline);
        if (modeOK) {
            char key[5]; fanKey(key, i, "Tg");
            // Do not clear a target while its fan is still in manual mode.
            writeNumber(connection, key, 0);
            double mode = readNumber(connection, ownedModeKeys[i]);
            modeOK = mode == 0 || mode == 3;
            if (!modeOK) snprintf(diagnostic, sizeof(diagnostic), "%s readback=%.0f expected=auto", ownedModeKeys[i], mode);
        }
        if (modeOK) controlledFans &= ~(1u << i);
        else if (!firstFailure[0]) memcpy(firstFailure, diagnostic, sizeof(firstFailure));
    }
    // The global flag stays enabled while any owned fan still needs it.
    int unlockOK = 1;
    if (!controlledFans && unlockedThermalControl) {
        unlockOK = canChangeThermalControl(connection) && writeWithRetry(connection, "Ftst", 0, deadline);
        if (unlockOK) unlockedThermalControl = 0;
        else if (!firstFailure[0]) memcpy(firstFailure, diagnostic, sizeof(firstFailure));
    }
    IOServiceClose(connection);
    memcpy(diagnostic, firstFailure, sizeof(diagnostic));
    return !(controlledFans & restoring) && unlockOK ? 0 : 6;
}

int PVSetFanManual(int fan, double rpm) {
    diagnostic[0] = 0;
    if (geteuid() != 0) return 1;
    if (fan < 0 || fan >= PV_MAX_FANS || !isfinite(rpm) || floor(rpm) != rpm) return 3;
    io_connect_t connection = openSMC();
    if (!connection) return 2;
    int count = fanCountForConnection(connection);
    if (fan >= count) { IOServiceClose(connection); return 3; }
    PVFanStatus status = statusForFan(connection, fan);
    if (!status.controllable || rpm < status.minimum || rpm > status.maximum) {
        IOServiceClose(connection);
        return 3;
    }
    if (!(controlledFans & (1u << fan)) && status.mode == 1) {
        IOServiceClose(connection);
        return 5;
    }
    char modeKey[5], targetKey[5];
    double currentMode = readMode(connection, fan, modeKey);
    if (!(controlledFans & (1u << fan)) && currentMode == 1) { IOServiceClose(connection); return 5; }
    if (currentMode != 0 && currentMode != 1 && currentMode != 3) { IOServiceClose(connection); return 3; }
    fanKey(targetKey, fan, "Tg");
    memcpy(ownedModeKeys[fan], modeKey, sizeof(modeKey));
    // Track ownership before a write that may apply despite an error return.
    controlledFans |= 1u << fan;
    int enabled = writeWithRetry(connection, modeKey, 1, controlDeadline());
    if (!enabled) {
        double thermal = readNumber(connection, "Ftst");
        int unlocked = thermal == 1;
        if (thermal == 0 && canChangeThermalControl(connection)) {
            unlockedThermalControl = 1;
            unlocked = writeWithRetry(connection, "Ftst", 1, controlDeadline());
            if (unlocked) usleep(3000000);
        }
        if (unlocked) enabled = writeWithRetry(connection, modeKey, 1, controlDeadline());
    }
    int speedOK = enabled && writeWithRetry(connection, targetKey, rpm, controlDeadline());
    double mode = readNumber(connection, modeKey), target = readNumber(connection, targetKey);
    IOServiceClose(connection);
    if (speedOK && mode == 1 && isfinite(target) && fabs(target - rpm) <= 1) {
        diagnostic[0] = 0;
        return 0;
    }
    if (!diagnostic[0]) snprintf(diagnostic, sizeof(diagnostic), "%s mode=%.0f target=%.0f expected=%.0f", targetKey, mode, target, rpm);
    char failure[sizeof(diagnostic)];
    memcpy(failure, diagnostic, sizeof(failure));
    // Roll back only the affected fan; other independent targets stay intact.
    int restored = PVRestoreFanAutomatic(fan);
    if (!restored) memcpy(diagnostic, failure, sizeof(diagnostic));
    return restored == 0 ? 4 : 6;
}

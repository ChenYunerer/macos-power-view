// Mock the IOKit transport, exercising production control and rollback logic.
// No hardware connection or privileged process is used by this test.
#include <IOKit/IOKitLib.h>
#include <unistd.h>
#include <sys/sysctl.h>
#define IOServiceGetMatchingService fakeService
#define IOServiceOpen fakeOpen
#define IOObjectRelease fakeRelease
#define IOServiceClose fakeClose
#define IOConnectCallStructMethod fakeCall
#define geteuid fakeEUID
#define usleep fakeSleep
#define sysctlbyname fakeSysctl
static io_service_t fakeService(mach_port_t, CFDictionaryRef);
static kern_return_t fakeOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
static kern_return_t fakeRelease(io_object_t);
static kern_return_t fakeClose(io_connect_t);
static kern_return_t fakeCall(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
static int fakeSysctl(const char *, void *, size_t *, void *, size_t);
static uid_t fakeEUID(void) { return 0; }
static int fakeSleep(useconds_t duration) { return 0; }
#include "../Sources/ThermalSensors/FanSensors.c"
#include <assert.h>

typedef struct {
    double mode, target, actual, minimum, maximum;
    int lag, pending, transient, rejectMode, mismatch, appliedError, rejectAuto, systemAuto, lowerMode, missing;
    int writes, zeroWrites;
    const char *name;
    int stringName;
} MockFan;
static MockFan fans[PV_MAX_FANS];
static int fanCount, writes, flagPresent, flagValue, flagRequired, flagRejectAuto, flagAppliedError;
static const char *chipName = "Apple M4 Pro";
static int sysctlFailure, noSMC, opened, closed, missingTemperatures, temperatureDataFailure, shortTemperatureReply;
static uint32_t temperatureType;
static const char *const temperatureKeys[] = { "Te05", "Te06", "Tp0H", "Tg1U", "Tg1k", "Tg0k" };
static double temperatureValues[6];
static int fakeSysctl(const char *name, void *output, size_t *size, void *input, size_t inputSize) {
    assert(!strcmp(name, "machdep.cpu.brand_string") && !input && inputSize == 0);
    if (sysctlFailure) return -1;
    size_t length = strlen(chipName) + 1;
    assert(*size >= length);
    memcpy(output, chipName, length);
    *size = length;
    return 0;
}
static io_service_t fakeService(mach_port_t port, CFDictionaryRef match) { CFRelease(match); return noSMC ? 0 : 1; }
static kern_return_t fakeOpen(io_service_t service, task_port_t task, uint32_t type, io_connect_t *connection) { opened++; *connection = 1; return 0; }
static kern_return_t fakeRelease(io_object_t object) { return 0; }
static kern_return_t fakeClose(io_connect_t connection) { closed++; return 0; }
static kern_return_t fakeCall(mach_port_t connection, uint32_t selector, const void *bytes, size_t length, void *result, size_t *size) {
    const SMCPacket *in = bytes;
    SMCPacket *out = result;
    memset(out, 0, sizeof(*out));
    assert(length == 80 && *size == 80 && selector == 2);
    uint32_t key = in->key;
    if (key >> 24 == 'T') {
        assert(in->command == 9 || in->command == 5);
        if (shortTemperatureReply) { *size = 0; return 0; }
        for (size_t i = 0; i < sizeof(temperatureKeys) / sizeof(temperatureKeys[0]); i++) {
            if (key != keyCode(temperatureKeys[i]) || missingTemperatures) continue;
            if (in->command == 9) {
                out->info.size = temperatureType == keyCode("ui8 ") ? 1 : 4;
                out->info.type = temperatureType;
            } else {
                if (temperatureDataFailure) return kIOReturnError;
                float value = temperatureValues[i];
                memcpy(out->bytes, &value, sizeof(value));
            }
            return 0;
        }
        out->result = 0x84;
        return 0;
    }
    if (key == keyCode("FNum")) {
        assert(in->command != 6);
        if (in->command == 9) { out->info.size = 1; out->info.type = keyCode("ui8 "); }
        else out->bytes[0] = fanCount;
        return 0;
    }
    if (key == keyCode("Ftst")) {
        if (!flagPresent) { out->result = 0x84; return 0; }
        if (in->command == 9) { out->info.size = 1; out->info.type = keyCode("ui8 "); }
        else if (in->command == 5) out->bytes[0] = flagValue;
        else {
            writes++;
            if (!in->bytes[0] && flagRejectAuto) { out->result = 0x82; return 0; }
            flagValue = in->bytes[0];
            if (flagAppliedError) out->result = 0x87;
        }
        return 0;
    }
    char keyText[5] = { key >> 24, key >> 16, key >> 8, key, 0 };
    const char *digits = "0123456789ABCDEF", *digit = strchr(digits, keyText[1]);
    assert(keyText[0] == 'F' && digit);
    int index = (int)(digit - digits);
    if (index >= fanCount || fans[index].missing) { out->result = 0x84; return 0; }
    MockFan *fan = &fans[index];
    const char *suffix = keyText + 2;
    if (!strcmp(suffix, "ID")) {
        if (!fan->name) { out->result = 0x84; return 0; }
        assert(in->command != 6);
        if (in->command == 9) {
            out->info.size = fan->stringName ? 32 : 16;
            out->info.type = keyCode(fan->stringName ? "ch8*" : "{fds");
        } else {
            size_t offset = fan->stringName ? 0 : 4;
            size_t length = strlen(fan->name), available = fan->stringName ? 32 : 12;
            memcpy(out->bytes + offset, fan->name, length < available ? length : available);
        }
        return 0;
    }
    int isMode = !strcmp(suffix, "Md") || !strcmp(suffix, "md");
    if (isMode && strcmp(suffix, fan->lowerMode ? "md" : "Md")) { out->result = 0x84; return 0; }
    if (in->command == 9) { out->info.size = isMode ? 1 : 4; out->info.type = keyCode(isMode ? "ui8 " : "flt "); return 0; }
    if (in->command == 6) {
        writes++; fan->writes++;
        float value = 0;
        if (isMode) value = in->bytes[0]; else memcpy(&value, in->bytes, 4);
        if (value > 0 && fan->transient-- > 0) return kIOReturnBusy;
        if (isMode) {
            if (value == 0 && fan->rejectAuto) { out->result = 0x82; return 0; }
            if (value == 1 && (fan->rejectMode || (flagRequired && !flagValue))) { out->result = 0x82; return 0; }
            fan->mode = value == 0 && fan->systemAuto ? 3 : value;
        } else if (!strcmp(suffix, "Tg")) {
            if (value == 0) fan->zeroWrites++;
            if (!fan->mismatch || value == 0) fan->target = value == 0 && fan->systemAuto ? 1200 : value;
            fan->pending = value > 0 ? fan->lag : 0;
            if (value > 0 && fan->appliedError) out->result = 0x87;
        } else assert(0);
        return 0;
    }
    assert(in->command == 5);
    float value = !strcmp(suffix, "Mn") ? fan->minimum : !strcmp(suffix, "Mx") ? fan->maximum
        : !strcmp(suffix, "Tg") ? (fan->pending-- > 0 ? 0 : fan->target) : !strcmp(suffix, "Ac") ? fan->actual : 0;
    if (isMode) out->bytes[0] = fan->mode; else memcpy(out->bytes, &value, 4);
    return 0;
}
static void reset(void) {
    controlledFans = unlockedThermalControl = 0;
    memset(ownedModeKeys, 0, sizeof(ownedModeKeys));
    memset(fans, 0, sizeof(fans));
    for (int i = 0; i < PV_MAX_FANS; i++) {
        fans[i].minimum = i ? 2317 : 1199;
        fans[i].maximum = i ? 7826 : 7199;
        fans[i].actual = i ? 2500 : 2000;
    }
    writes = flagPresent = flagValue = flagRequired = flagRejectAuto = flagAppliedError = 0;
    fanCount = 1;
    chipName = "Apple M4 Pro";
    sysctlFailure = noSMC = opened = closed = missingTemperatures = temperatureDataFailure = shortTemperatureReply = 0;
    temperatureType = keyCode("flt ");
    double values[] = { 52, 62, 68, 45, 49, 56 };
    memcpy(temperatureValues, values, sizeof(values));
}
int main(void) {
    reset(); fans[0].lag = 4;
    assert(PVSetFanManual(0, 3000) == 0 && fans[0].mode == 1 && fans[0].target == 3000);
    assert(PVRestoreFanAutomatic(-1) == 0 && fans[0].mode == 0 && fans[0].target == 0);
    reset(); fans[0].transient = 3;
    assert(PVSetFanManual(0, 3000) == 0);
    reset(); fans[0].appliedError = 1;
    assert(PVSetFanManual(0, 3000) == 0);
    reset(); fans[0].rejectMode = 1;
    assert(PVSetFanManual(0, 3000) == 4 && fans[0].mode == 0 && fans[0].target == 0);
    assert(strstr(PVFanControlDiagnostic(), "F0Md") && strstr(PVFanControlDiagnostic(), "smc=0x82"));
    reset(); fans[0].mismatch = 1;
    assert(PVSetFanManual(0, 3000) == 4 && fans[0].mode == 0 && fans[0].target == 0);
    assert(strstr(PVFanControlDiagnostic(), "F0Tg readback=0 expected=3000"));
    reset();
    assert(PVSetFanManual(0, 0) == 3 && PVSetFanManual(-1, 3000) == 3 && PVSetFanManual(1, 3000) == 3 && writes == 0);
    assert(PVRestoreFanAutomatic(-1) == 0 && writes == 0); // No owned fans.
    reset(); assert(PVSetFanManual(0, 3000) == 0); fans[0].rejectAuto = 1;
    assert(PVRestoreFanAutomatic(-1) == 6 && fans[0].mode == 1 && fans[0].target == 3000 && fans[0].zeroWrites == 0);
    reset(); assert(PVSetFanManual(0, 3000) == 0); fans[0].systemAuto = 1;
    assert(PVRestoreFanAutomatic(-1) == 0 && fans[0].mode == 3 && fans[0].target == 1200);

    reset(); fanCount = 2; fans[1].lowerMode = 1;
    PVFanStatus states[PV_MAX_FANS];
    assert(PVReadFanStatuses(states, PV_MAX_FANS) == 2 && opened == 1 && closed == 1);
    assert(states[0].id == 0 && states[1].id == 1 && states[0].controllable && states[1].controllable);
    assert(states[0].name[0] == 0 && states[1].name[0] == 0);
    fans[0].name = "Left side"; fans[1].name = "Right side"; fans[1].stringName = 1;
    assert(PVReadFanStatuses(states, PV_MAX_FANS) == 2);
    assert(!strcmp(states[0].name, "Left side") && !strcmp(states[1].name, "Right side"));
    fans[1].name = "012345678901234567890123456789012345";
    assert(PVReadFanStatuses(states, PV_MAX_FANS) == 2 && strlen(states[1].name) == 31);
    fans[1].name = "invalid\nname";
    assert(PVReadFanStatuses(states, PV_MAX_FANS) == 2 && !states[1].name[0]);
    assert(states[0].minimum == 1199 && states[1].minimum == 2317 && states[1].actual == 2500);
    assert(PVSetFanManual(1, 2000) == 3 && writes == 0); // Per-fan range.
    assert(PVSetFanManual(0, 3000) == 0 && fans[1].writes == 0);
    assert(PVSetFanManual(1, 4200) == 0 && fans[0].target == 3000 && fans[1].target == 4200);
    assert(PVFanControlMask() == 3);
    assert(PVRestoreFanAutomatic(0) == 0 && fans[1].mode == 1 && fans[1].target == 4200 && PVFanControlMask() == 2);
    assert(PVRestoreFanAutomatic(-1) == 0 && fans[1].mode == 0 && !PVFanControlIsActive());

    reset(); fanCount = 2; fans[1].mode = 1; fans[1].target = 5000;
    assert(PVSetFanManual(1, 4000) == 5 && writes == 0);
    assert(PVSetFanManual(0, 3000) == 0);
    assert(PVRestoreFanAutomatic(-1) == 0 && fans[1].mode == 1 && fans[1].target == 5000 && fans[1].writes == 0);

    reset(); fanCount = 2;
    assert(PVSetFanManual(0, 3000) == 0);
    fans[1].mismatch = 1;
    assert(PVSetFanManual(1, 4200) == 4 && fans[0].mode == 1 && fans[0].target == 3000 && fans[1].mode == 0);
    assert(PVFanControlMask() == 1 && strstr(PVFanControlDiagnostic(), "F1Tg"));
    fans[1].mismatch = 0;
    assert(PVSetFanManual(1, 4200) == 0);
    fans[0].rejectAuto = 1;
    assert(PVRestoreFanAutomatic(-1) == 6 && fans[0].target == 3000 && fans[0].zeroWrites == 0 && fans[1].mode == 0);
    assert(PVFanControlMask() == 1 && strstr(PVFanControlDiagnostic(), "F0Md"));
    fans[0].rejectAuto = 0; fanCount = 0; // Remember ownership even if enumeration fails.
    assert(PVRestoreFanAutomatic(-1) == 6 && PVFanControlMask() == 1);
    fanCount = 2;
    assert(PVRestoreFanAutomatic(-1) == 0 && !PVFanControlIsActive());

    reset(); fanCount = 2; flagPresent = flagRequired = flagAppliedError = 1;
    assert(PVSetFanManual(0, 3000) == 0 && flagValue == 1);
    assert(PVSetFanManual(1, 4200) == 0);
    assert(PVRestoreFanAutomatic(0) == 0 && flagValue == 1 && fans[1].mode == 1);
    flagRejectAuto = 1;
    assert(PVRestoreFanAutomatic(1) == 6 && PVFanControlMask() == 0 && PVFanControlIsActive());
    flagRejectAuto = 0;
    assert(PVRestoreFanAutomatic(-1) == 0 && flagValue == 0 && !PVFanControlIsActive());
    reset(); flagPresent = flagRequired = flagValue = 1;
    assert(PVSetFanManual(0, 3000) == 0 && PVRestoreFanAutomatic(-1) == 0 && flagValue == 1); // Do not clear a pre-existing flag.

    reset(); fanCount = 2; flagPresent = flagRequired = 1;
    fans[1].mode = 1; fans[1].target = 5000;
    assert(PVSetFanManual(0, 3000) == 4 && flagValue == 0 && fans[1].writes == 0);
    reset(); fanCount = 2; flagPresent = flagRequired = 1;
    assert(PVSetFanManual(0, 3000) == 0);
    fans[1].mode = 1; fans[1].target = 5000; // Another controller starts after our SET.
    assert(PVRestoreFanAutomatic(0) == 6 && fans[0].mode == 0 && flagValue == 1 && fans[1].writes == 0);
    fans[1].mode = 0;
    assert(PVRestoreFanAutomatic(-1) == 0 && flagValue == 0);

    reset(); fanCount = PV_MAX_FANS;
    for (int i = 0; i < fanCount; i++) assert(PVSetFanManual(i, 3000 + i) == 0);
    assert(PVFanControlMask() == 0xffffu && PVRestoreFanAutomatic(-1) == 0 && !PVFanControlIsActive());
    for (int i = 0; i < fanCount; i++) assert(fans[i].mode == 0);
    reset(); fanCount = 2; fans[1].missing = 1;
    assert(PVReadFanStatuses(states, PV_MAX_FANS) == 2 && states[0].controllable && !states[1].controllable);
    assert(PVSetFanManual(1, 3000) == 3 && writes == 0);
    assert(PVReadFanStatuses(states, 1) == 0);
    fanCount = 0;
    assert(PVReadFanStatuses(states, PV_MAX_FANS) == 0);
    fanCount = 17;
    assert(PVReadFanStatuses(states, PV_MAX_FANS) == 0);
    puts("Passed per-fan SMC checks: independent ranges/targets, ownership, rollback, partial restore, shared flag, 16 fans, readback, diagnostics.");

    reset();
    PVProcessorTemperatures temperatures = PVReadSMCProcessorTemperatures();
    assert(temperatures.cpu == 68 && temperatures.gpu == 56);
    assert(opened == 1 && closed == 1 && writes == 0);
    const char *otherChips[] = { "Apple M1", "Apple M4", "Apple M4 Max", "Apple M5 Pro", "" };
    for (size_t i = 0; i < sizeof(otherChips) / sizeof(otherChips[0]); i++) {
        reset(); chipName = otherChips[i];
        temperatures = PVReadSMCProcessorTemperatures();
        assert(isnan(temperatures.cpu) && isnan(temperatures.gpu) && opened == 0);
    }
    reset(); sysctlFailure = 1;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu) && opened == 0);
    reset(); noSMC = 1;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu) && opened == 0);
    reset(); missingTemperatures = 1;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu) && opened == closed && writes == 0);
    reset(); temperatureDataFailure = 1;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu) && opened == closed);
    reset(); shortTemperatureReply = 1;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu) && opened == closed);
    reset(); temperatureType = keyCode("ui8 ");
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu));
    reset(); temperatureType = keyCode("xxxx");
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu));
    reset();
    double invalid[] = { NAN, INFINITY, -1, 0, 126, -INFINITY };
    memcpy(temperatureValues, invalid, sizeof(invalid));
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu));
    temperatureValues[1] = 125;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(temperatures.cpu == 125 && isnan(temperatures.gpu));
    temperatureValues[4] = 0.5;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(temperatures.cpu == 125 && temperatures.gpu == 0.5 && writes == 0);
    // Each sample starts empty; unavailable data cannot retain earlier values.
    missingTemperatures = 1;
    temperatures = PVReadSMCProcessorTemperatures();
    assert(isnan(temperatures.cpu) && isnan(temperatures.gpu) && opened == closed);
    puts("Passed SMC temperature checks: M4 Pro mapping, model gate, hottest valid reading, failures, fresh samples, read-only transport.");
}

// Mock the IOKit transport, exercising production control and rollback logic.
// No hardware connection or privileged process is used by this test.
#include <IOKit/IOKitLib.h>
#include <unistd.h>
#define IOServiceGetMatchingService fakeService
#define IOServiceOpen fakeOpen
#define IOObjectRelease fakeRelease
#define IOServiceClose fakeClose
#define IOConnectCallStructMethod fakeCall
#define geteuid fakeEUID
#define usleep fakeSleep
static io_service_t fakeService(mach_port_t, CFDictionaryRef);
static kern_return_t fakeOpen(io_service_t, task_port_t, uint32_t, io_connect_t *);
static kern_return_t fakeRelease(io_object_t);
static kern_return_t fakeClose(io_connect_t);
static kern_return_t fakeCall(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
static uid_t fakeEUID(void) { return 0; }
static int fakeSleep(useconds_t duration) { return 0; }
#include "../Sources/ThermalSensors/FanSensors.c"
#include <assert.h>

static double mode, target;
static int lag, pending, transient, rejectMode, mismatch, appliedError, writes, rejectAuto, systemAuto;
static int fanCount = 1;
static io_service_t fakeService(mach_port_t port, CFDictionaryRef match) { CFRelease(match); return 1; }
static kern_return_t fakeOpen(io_service_t service, task_port_t task, uint32_t type, io_connect_t *connection) { *connection = 1; return 0; }
static kern_return_t fakeRelease(io_object_t object) { return 0; }
static kern_return_t fakeClose(io_connect_t connection) { return 0; }
static kern_return_t fakeCall(mach_port_t connection, uint32_t selector, const void *bytes, size_t length, void *result, size_t *size) {
    const SMCPacket *in = bytes;
    SMCPacket *out = result;
    memset(out, 0, sizeof(*out));
    assert(length == 80 && *size == 80 && selector == 2);
    uint32_t key = in->key;
    if (key == keyCode("F0md") || key == keyCode("Ftst")) { out->result = 0x84; return 0; }
    int small = key == keyCode("FNum") || key == keyCode("F0Md");
    if (in->command == 9) { out->info.size = small ? 1 : 4; out->info.type = keyCode(small ? "ui8 " : "flt "); return 0; }
    if (in->command == 6) {
        writes++;
        float value = 0;
        if (small) value = in->bytes[0]; else memcpy(&value, in->bytes, 4);
        if (value > 0 && transient-- > 0) return kIOReturnBusy;
        if (key == keyCode("F0Md")) {
            if (value == 0 && rejectAuto) { out->result = 0x82; return 0; }
            if (value == 1 && rejectMode) { out->result = 0x82; return 0; }
            mode = value == 0 && systemAuto ? 3 : value;
        } else if (key == keyCode("F0Tg")) {
            if (!mismatch || value == 0) target = value == 0 && systemAuto ? 1200 : value;
            pending = value > 0 ? lag : 0;
            if (value > 0 && appliedError) out->result = 0x87;
        } else assert(0);
        return 0;
    }
    assert(in->command == 5);
    float value = key == keyCode("F0Mn") ? 1199 : key == keyCode("F0Mx") ? 7199
        : key == keyCode("F0Tg") ? (pending-- > 0 ? 0 : target) : key == keyCode("F1Ac") ? 5000 : 0;
    if (small) out->bytes[0] = key == keyCode("FNum") ? fanCount : mode;
    else memcpy(out->bytes, &value, 4);
    return 0;
}
static void reset(void) {
    mode = target = 0;
    lag = pending = transient = rejectMode = mismatch = appliedError = writes = 0;
    rejectAuto = systemAuto = 0;
    fanCount = 1;
}
int main(void) {
    reset(); lag = 4;
    assert(PVSetFanManual(3000) == 0 && mode == 1 && target == 3000);
    assert(PVRestoreFanAutomatic() == 0 && mode == 0 && target == 0);
    reset(); transient = 3;
    assert(PVSetFanManual(3000) == 0);
    reset(); appliedError = 1;
    assert(PVSetFanManual(3000) == 0); // Confirmed write despite firmware error.
    reset(); rejectMode = 1;
    assert(PVSetFanManual(3000) == 4 && mode == 0 && target == 0);
    assert(strstr(PVFanControlDiagnostic(), "F0Md") && strstr(PVFanControlDiagnostic(), "smc=0x82"));
    reset(); mismatch = 1;
    assert(PVSetFanManual(3000) == 4 && mode == 0 && target == 0);
    assert(strstr(PVFanControlDiagnostic(), "F0Tg readback=0 expected=3000"));
    reset();
    assert(PVSetFanManual(0) == 3 && writes == 0);
    reset(); mode = 1; target = 3000; rejectAuto = 1;
    assert(PVRestoreFanAutomatic() == 6 && mode == 1 && target == 3000); // Never stop a fan still in manual mode.
    reset(); mode = 1; target = 3000; systemAuto = 1;
    assert(PVRestoreFanAutomatic() == 0 && mode == 3 && target == 1200); // System chooses its own speed.
    reset(); fanCount = 2;
    PVFanStatus fans = PVReadFanStatus();
    assert(fans.actual == 5000 && !fans.controllable && fans.count == 2);
    assert(PVSetFanManual(3000) == 3 && writes == 0);
    fanCount = 0;
    fans = PVReadFanStatus();
    assert(isnan(fans.actual) && !fans.controllable);
    puts("Passed SMC control checks: delayed readback, transient rejection, applied error, rollback, diagnostics, bounds.");
}

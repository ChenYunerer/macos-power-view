#ifndef POWER_VIEW_THERMAL_SENSORS_H
#define POWER_VIEW_THERMAL_SENSORS_H

// The handler is called synchronously; name is valid only during the callback.
typedef void (*PVTemperatureHandler)(const char *name, double celsius, void *context);
void PVReadTemperatureSensors(PVTemperatureHandler handler, void *context);
typedef int (*PVTemperatureFilter)(const char *name);
void PVReadTemperatureSensorsMatching(PVTemperatureFilter filter, PVTemperatureHandler handler, void *context);
// Read-only fallback for verified processor sensor layouts; NAN means unavailable.
typedef struct { double cpu, gpu; } PVProcessorTemperatures;
PVProcessorTemperatures PVReadSMCProcessorTemperatures(void);
// Fastest fan by RPM on multi-fan machines; NAN means unavailable. Read-only.
double PVReadFanRPM(void);

typedef struct {
    double actual, minimum, maximum, target;
    int id, mode, controllable;
    char name[32]; // Optional SMC fan description, UTF-8/NUL terminated.
} PVFanStatus;
enum { PV_MAX_FANS = 16 };
// Returns the fan count, or zero when unavailable. One connection per sample.
int PVReadFanStatuses(PVFanStatus *statuses, int capacity);
// Only the privileged helper invokes these operations. Non-root callers fail.
int PVSetFanManual(int fan, double rpm);
// -1 restores every fan owned by this helper; otherwise restores only that fan.
int PVRestoreFanAutomatic(int fan);
unsigned int PVFanControlMask(void);
int PVFanControlIsActive(void);
// Diagnostic for the last control operation on the current thread.
const char *PVFanControlDiagnostic(void);

#endif

#ifndef POWER_VIEW_THERMAL_SENSORS_H
#define POWER_VIEW_THERMAL_SENSORS_H

// The handler is called synchronously; name is valid only during the callback.
typedef void (*PVTemperatureHandler)(const char *name, double celsius, void *context);
void PVReadTemperatureSensors(PVTemperatureHandler handler, void *context);
typedef int (*PVTemperatureFilter)(const char *name);
void PVReadTemperatureSensorsMatching(PVTemperatureFilter filter, PVTemperatureHandler handler, void *context);
// Fastest fan by RPM on multi-fan machines; NAN means unavailable. Read-only.
double PVReadFanRPM(void);

typedef struct {
    double actual, minimum, maximum, target;
    int count, mode, controllable;
} PVFanStatus;
PVFanStatus PVReadFanStatus(void);
// Only the privileged helper invokes these operations. Non-root callers fail.
int PVSetFanManual(double rpm);
int PVRestoreFanAutomatic(void);
// Diagnostic for the last control operation on the current thread.
const char *PVFanControlDiagnostic(void);

#endif

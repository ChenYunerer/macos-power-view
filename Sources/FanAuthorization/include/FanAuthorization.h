#ifndef POWER_VIEW_FAN_AUTHORIZATION_H
#define POWER_VIEW_FAN_AUTHORIZATION_H
#include <stddef.h>
typedef struct PVFanSession PVFanSession;
int PVOpenFanSession(const char *helperPath, PVFanSession **session);
int PVFanSessionCommand(PVFanSession *session, const char *command, char *reply, size_t capacity);
void PVCloseFanSession(PVFanSession *session);
#endif

#include "FanAuthorization.h"
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>

struct PVFanSession { FILE *pipe; AuthorizationRef authorization; };

static int readLine(int fd, char *reply, size_t capacity) {
    if (capacity < 2) return -1;
    size_t count = 0;
    // Wall-clock changes must not lengthen or prematurely expire IPC waits.
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 12000000000ULL;
    while (count < capacity - 1 && clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) < deadline) {
        struct pollfd p = { fd, POLLIN, 0 };
        int status = poll(&p, 1, 1000);
        if (status < 0 && errno == EINTR) continue;
        if (status < 0 || (p.revents & (POLLERR | POLLNVAL))) break;
        if (!status) continue;
        char c;
        ssize_t bytes = read(fd, &c, 1);
        if (bytes < 0 && errno == EINTR) continue;
        if (bytes != 1) break;
        if (c == '\n') { reply[count] = 0; return 0; }
        reply[count++] = c;
    }
    reply[0] = 0;
    return -1;
}

int PVOpenFanSession(const char *helperPath, PVFanSession **session) {
    *session = NULL;
    PVFanSession *value = calloc(1, sizeof(*value));
    if (!value) return -1;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, 0, &value->authorization);
    if (status == errAuthorizationSuccess) {
        AuthorizationItem item = { kAuthorizationRightExecute, strlen(helperPath), (void *)helperPath, 0 };
        AuthorizationRights rights = { 1, &item };
        status = AuthorizationCopyRights(value->authorization, &rights, kAuthorizationEmptyEnvironment,
            kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights, NULL);
    }
    if (status == errAuthorizationSuccess) {
        char *arguments[] = { NULL };
        // This session-only helper uses the native authorization dialog and
        // installs no persistent service. Release signing is handled separately;
        // migration to an authenticated SMAppService helper remains future work.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        status = AuthorizationExecuteWithPrivileges(value->authorization, helperPath, 0, arguments, &value->pipe);
#pragma clang diagnostic pop
    }
    if (status != errAuthorizationSuccess || !value->pipe) {
        PVCloseFanSession(value);
        return status == 0 ? -1 : status;
    }
    setvbuf(value->pipe, NULL, _IONBF, 0);
    fcntl(fileno(value->pipe), F_SETNOSIGPIPE, 1);
    fcntl(fileno(value->pipe), F_SETFD, FD_CLOEXEC);
    char reply[128];
    if (readLine(fileno(value->pipe), reply, sizeof(reply)) || strcmp(reply, "READY")) {
        PVCloseFanSession(value);
        return -2;
    }
    *session = value;
    return 0;
}

int PVFanSessionCommand(PVFanSession *session, const char *command, char *reply, size_t capacity) {
    if (!session || !session->pipe || strlen(command) > 64 || strchr(command, '\n')) return -1;
    char buffer[80];
    int length = snprintf(buffer, sizeof(buffer), "%s\n", command);
    int fd = fileno(session->pipe), sent = 0;
    while (sent < length) {
        ssize_t count = write(fd, buffer + sent, length - sent);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        sent += (int)count;
    }
    return readLine(fd, reply, capacity);
}

void PVCloseFanSession(PVFanSession *session) {
    if (!session) return;
    if (session->pipe) fclose(session->pipe); // EOF makes the helper restore auto.
    if (session->authorization) AuthorizationFree(session->authorization, kAuthorizationFlagDestroyRights);
    free(session);
}

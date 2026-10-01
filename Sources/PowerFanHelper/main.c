#include "ThermalSensors.h"
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>

static volatile sig_atomic_t stopped = 0;
static int simulation = 0, owned = 0;
static void stop(int signalNumber) { stopped = 1; }
static double now(void) {
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return (double)mach_continuous_time() * base.numer / base.denom / 1e9;
}
static int restore(void) {
    if (!owned) return 0;
    int result = simulation ? 0 : PVRestoreFanAutomatic();
    if (!result) owned = 0;
    return result;
}

static int command(const char *line) {
    if (!strcmp(line, "PING")) { puts("OK"); return 1; }
    if (!strcmp(line, "AUTO") || !strcmp(line, "QUIT")) {
        int result = restore();
        if (result) printf("ERR %d\n", result); else puts("OK");
        return strcmp(line, "QUIT") != 0;
    }
    if (!strncmp(line, "SET ", 4)) {
        char *end;
        errno = 0;
        double rpm = strtod(line + 4, &end);
        PVFanStatus state = simulation ? (PVFanStatus){0, 1199, 7199, 0, 1, 0, 1} : PVReadFanStatus();
        if (end == line + 4 || *end || errno || !isfinite(rpm) || floor(rpm) != rpm
            || !state.controllable || rpm < state.minimum || rpm > state.maximum) {
            puts("ERR 3"); return 1;
        }
        if (!owned && state.mode == 1) { puts("ERR 5"); return 1; }
        owned = 1; // Also covers partially applied changes that need rollback.
        int result = simulation ? 0 : PVSetFanManual(rpm);
        if (result) {
            char detail[176];
            snprintf(detail, sizeof(detail), "%s", PVFanControlDiagnostic());
            int restored = restore();
            printf("ERR %d%s%s\n", restored ? 6 : (result == 6 ? 4 : result), detail[0] ? "|" : "", detail);
        } else puts("OK");
        return 1;
    }
    puts("ERR 7");
    return 1;
}

int main(int argc, char **argv) {
    // Simulation exercises the exact parser/watchdog without touching hardware.
    simulation = argc >= 2 && !strcmp(argv[1], "--simulate");
    double timeout = simulation && argc == 3 ? atof(argv[2]) : 20;
    if (!isfinite(timeout) || timeout < 0.1 || timeout > 20) return 2;
    if (!simulation && (argc != 1 || geteuid() != 0)) return 1;
    // AuthorizationExecuteWithPrivileges changes EUID only. Establish the
    // helper's real identity before opening driver connections as root.
    if (!simulation && (setuid(0) != 0 || getuid() != 0)) return 1;
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    signal(SIGHUP, stop);
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IONBF, 0);
    puts(simulation ? "SIMULATED READY" : "READY");
    char line[80];
    size_t count = 0;
    double deadline = now() + timeout;
    int running = 1;
    while (running && !stopped && now() < deadline) {
        struct pollfd input = { STDIN_FILENO, POLLIN, 0 };
        // Block until input, a signal, or the watchdog deadline instead of
        // waking ten times per second throughout every manual-control session.
        int waitMS = (int)fmax(1, ceil((deadline - now()) * 1000));
        int result = poll(&input, 1, waitMS);
        if (stopped || now() >= deadline) break;
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (input.revents & (POLLERR | POLLNVAL))) break;
        if (!result) continue;
        char c;
        ssize_t bytes = read(STDIN_FILENO, &c, 1);
        if (bytes < 0 && errno == EINTR) continue;
        if (bytes != 1) break;
        if (c == '\n') {
            line[count] = 0;
            running = command(line);
            count = 0;
            deadline = now() + timeout;
        } else {
            if (count == sizeof(line) - 1 || c == '\0') break;
            line[count++] = c;
        }
    }
    int wasOwned = owned;
    int restored = restore();
    for (int attempt = 0; restored && attempt < 4; attempt++) {
        usleep(200000);
        restored = restore();
    }
    if (simulation && wasOwned) puts("RESTORED_ON_EXIT");
    if (restored) fputs("Automatic fan restoration failed; check system fan control.\n", stderr);
    return restored ? 1 : 0;
}

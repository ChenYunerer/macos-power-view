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
static int simulation = 0;
static unsigned int simulatedOwned = 0;
static void stop(int signalNumber) { stopped = 1; }
static double now(void) {
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return (double)mach_continuous_time() * base.numer / base.denom / 1e9;
}
static unsigned int ownership(void) { return simulation ? simulatedOwned : PVFanControlMask(); }
static int active(void) { return simulation ? simulatedOwned != 0 : PVFanControlIsActive(); }
static int restore(void) {
    if (simulation) { simulatedOwned = 0; return 0; }
    return PVRestoreFanAutomatic(-1);
}
static void reply(int result) {
    if (!result) printf("OK %u %d\n", ownership(), active());
    else {
        const char *detail = simulation ? "" : PVFanControlDiagnostic();
        printf("ERR %d %u %d%s%s\n", result, ownership(), active(), detail[0] ? "|" : "", detail);
    }
}

static int command(const char *line) {
    if (!strcmp(line, "PING")) { reply(0); return 1; }
    if (!strcmp(line, "AUTO") || !strcmp(line, "QUIT")) {
        reply(restore());
        return strcmp(line, "QUIT") != 0;
    }
    if (!strncmp(line, "AUTO ", 5)) {
        char *end;
        errno = 0;
        long fan = strtol(line + 5, &end, 10);
        if (end == line + 5 || *end || errno || fan < 0 || fan >= PV_MAX_FANS || (simulation && fan >= 2)) reply(3);
        else if (simulation) { simulatedOwned &= ~(1u << fan); reply(0); }
        else reply(PVRestoreFanAutomatic((int)fan));
        return 1;
    }
    if (!strncmp(line, "SET ", 4)) {
        char *end;
        errno = 0;
        long fan = strtol(line + 4, &end, 10);
        if (end == line + 4 || *end != ' ' || errno || fan < 0 || fan >= PV_MAX_FANS) { reply(3); return 1; }
        const char *speed = end + 1;
        double rpm = strtod(speed, &end);
        if (end == speed || *end || errno || !isfinite(rpm) || floor(rpm) != rpm) { reply(3); return 1; }
        int result;
        if (simulation) {
            double minimum = fan == 0 ? 1199 : 2317, maximum = fan == 0 ? 7199 : 7826;
            result = fan >= 2 || rpm < minimum || rpm > maximum ? 3 : 0;
            if (!result) simulatedOwned |= 1u << fan;
        } else result = PVSetFanManual((int)fan, rpm);
        reply(result);
        return 1;
    }
    reply(7);
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
    unsigned int wasOwned = ownership();
    int restored = restore();
    for (int attempt = 0; restored && attempt < 4; attempt++) {
        usleep(200000);
        restored = restore();
    }
    if (simulation && wasOwned) printf("RESTORED_ON_EXIT %u\n", wasOwned);
    if (restored) fputs("Automatic fan restoration failed; check system fan control.\n", stderr);
    return restored ? 1 : 0;
}

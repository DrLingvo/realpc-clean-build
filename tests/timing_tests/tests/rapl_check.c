/*
 * RAPL availability and sanity. Reads the RAPL energy MSRs via /dev/cpu/0/msr and checks that
 * package energy actually increments over a short sleep. On a bare-metal Intel host these are
 * present and monotonically increasing; a plain VM has no RAPL MSRs (reads fault/zero). With
 * this project's host-sensors passthrough the guest should see real, increasing values — so
 * this doubles as a validation of that feature.
 *
 * Needs root and the host/guest 'msr' module (modprobe msr). Skips cleanly otherwise.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

#define MSR_RAPL_POWER_UNIT   0x606
#define MSR_PKG_ENERGY_STATUS 0x611
#define MSR_DRAM_ENERGY       0x619
#define MSR_PP0_ENERGY        0x639

static int rd(int fd, unsigned msr, unsigned long long *v) {
    return pread(fd, v, 8, msr) == 8 ? 0 : -1;
}

int main(int argc, char **argv) {
    int json = 0; for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--json")) json = 1;
    int fd = open("/dev/cpu/0/msr", O_RDONLY);
    if (fd < 0) {
        if (json) printf("{\"test\":\"rapl_check\",\"available\":false,\"reason\":\"no /dev/cpu/0/msr (root? modprobe msr?)\"}\n");
        else printf("rapl_check: /dev/cpu/0/msr not available (need root + modprobe msr)\n");
        return 0;
    }
    unsigned long long unit = 0, e0 = 0, e1 = 0, dram = 0, pp0 = 0;
    int have_unit = rd(fd, MSR_RAPL_POWER_UNIT, &unit) == 0;
    int have_pkg = rd(fd, MSR_PKG_ENERGY_STATUS, &e0) == 0;
    int have_dram = rd(fd, MSR_DRAM_ENERGY, &dram) == 0;
    int have_pp0 = rd(fd, MSR_PP0_ENERGY, &pp0) == 0;
    struct timespec ts = {0, 200000000}; nanosleep(&ts, NULL);  /* 200 ms */
    rd(fd, MSR_PKG_ENERGY_STATUS, &e1);
    close(fd);

    double energy_units = have_unit ? 1.0 / (1u << ((unit >> 8) & 0x1f)) : 0;
    long long delta = (long long)((e1 - e0) & 0xffffffffULL);
    int increasing = have_pkg && delta > 0;
    double joules = energy_units * (double)delta;

    if (json)
        printf("{\"test\":\"rapl_check\",\"available\":%s,\"power_unit\":%s,\"pkg\":%s,"
               "\"dram\":%s,\"pp0\":%s,\"pkg_increasing\":%s,\"delta_joules\":%.4f}\n",
               have_pkg ? "true" : "false", have_unit ? "true" : "false",
               have_pkg ? "true" : "false", have_dram ? "true" : "false",
               have_pp0 ? "true" : "false", increasing ? "true" : "false", joules);
    else
        printf("RAPL: unit=%d pkg=%d dram=%d pp0=%d  pkg_increasing=%d (%.3f J / 200ms)\n",
               have_unit, have_pkg, have_dram, have_pp0, increasing, joules);
    return 0;
}

/*
 * Architectural PMU presence via CPUID leaf 0x0A (Intel). A real modern CPU reports PMU
 * version >= 4, several general-purpose counters and >= 40-bit counter width. QEMU without
 * an explicit PMU, or with KVM PMU disabled, reports version 0 / no counters — a strong tell.
 * (This is a capability check; it does not read the counter MSRs, which need privilege.)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <cpuid.h>

int main(int argc, char **argv) {
    int json = 0; for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--json")) json = 1;
    uint32_t a = 0, b = 0, c = 0, d = 0;
    unsigned max = __get_cpuid_max(0, NULL);
    unsigned version = 0, gp = 0, width = 0, fixed = 0, fwidth = 0;
    if (max >= 0x0A) {
        __cpuid_count(0x0A, 0, a, b, c, d);
        version = a & 0xff;
        gp = (a >> 8) & 0xff;
        width = (a >> 16) & 0xff;
        fixed = d & 0x1f;
        fwidth = (d >> 5) & 0xff;
    }
    if (json)
        printf("{\"test\":\"pmu_check\",\"version\":%u,\"gp_counters\":%u,\"gp_width\":%u,"
               "\"fixed_counters\":%u,\"fixed_width\":%u}\n",
               version, gp, width, fixed, fwidth);
    else
        printf("PMU: version %u, GP counters %u (%u-bit), fixed %u (%u-bit)\n",
               version, gp, width, fixed, fwidth);
    return 0;
}

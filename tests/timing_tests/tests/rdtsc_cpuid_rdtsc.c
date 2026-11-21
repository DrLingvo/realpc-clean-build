/*
 * VM-exit latency detector.
 *
 * CPUID is unconditionally intercepted by KVM: on a guest each CPUID is a VM-exit ->
 * handler -> VM-entry, typically >1000 cycles AND with suspiciously low variance. On bare
 * metal CPUID is a few hundred cycles with high variance. The robust signal is the SHAPE
 * (low coefficient of variation at high latency), not an absolute cycle count — so we report
 * cv alongside the raw numbers. This is a known-hard case: on plain KVM the VM-exit cost
 * cannot really be hidden, so expect this test to flag "VM-like" even on a good setup.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include "../common/timing.h"
#include "../common/stats.h"

#define DEFAULT_SAMPLES 20000
#define WARMUP 2000

static void pin_to_cpu(int cpu) {
    cpu_set_t set; CPU_ZERO(&set); CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) < 0) perror("sched_setaffinity");
}

int main(int argc, char **argv) {
    int samples = DEFAULT_SAMPLES, json = 0;
    const char *dump_raw = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!strcmp(argv[i], "--samples") && i + 1 < argc) samples = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dump-raw") && i + 1 < argc) dump_raw = argv[++i];
    }
    pin_to_cpu(0);
    double tsc_hz = calibrate_tsc_hz();

    uint64_t *data = malloc((size_t)samples * sizeof(uint64_t));
    if (!data) { perror("malloc"); return 1; }
    for (int i = 0; i < WARMUP; i++) (void)measure_cpuid_latency();
    for (int i = 0; i < samples; i++) data[i] = measure_cpuid_latency();

    struct stats s = compute_stats(data, samples);
    /* optional: dump the raw per-sample cycle counts (binary uint64) so jitter_report.py
     * can model the effect of VM_EXIT_JITTER on the real distribution, not a synthetic one. */
    if (dump_raw) {
        FILE *f = fopen(dump_raw, "wb");
        if (f) { fwrite(data, sizeof(uint64_t), samples, f); fclose(f); }
        else perror("fopen --dump-raw");
    }
    free(data);
    double median_ns = tsc_hz > 0 ? s.median * 1e9 / tsc_hz : 0;

    if (json)
        printf("{\"test\":\"rdtsc_cpuid_rdtsc\",\"samples\":%d,\"median\":%.1f,"
               "\"p95\":%.1f,\"p99\":%.1f,\"stddev\":%.2f,\"cv\":%.4f,"
               "\"min\":%lu,\"max\":%lu,\"median_ns\":%.1f,\"tsc_hz\":%.0f}\n",
               samples, s.median, s.p95, s.p99, s.stddev, s.cv,
               (unsigned long)s.min, (unsigned long)s.max, median_ns, tsc_hz);
    else
        printf("VM-exit (cpuid) latency: median %.0f cyc (%.1f ns), p99 %.0f, "
               "stddev %.1f, cv %.3f, min %lu, max %lu\n",
               s.median, median_ns, s.p99, s.stddev, s.cv,
               (unsigned long)s.min, (unsigned long)s.max);
    return 0;
}

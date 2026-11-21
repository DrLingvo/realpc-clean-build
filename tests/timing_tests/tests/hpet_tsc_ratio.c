/*
 * Timer coherence: the ratio TSC_delta / wallclock_delta should be rock-stable on real
 * hardware (invariant TSC). We sample TSC against CLOCK_MONOTONIC_RAW over many short
 * intervals and report the ratio's coefficient of variation. (Reading the HPET main counter
 * directly needs root + MMIO via /dev/mem; CLOCK_MONOTONIC_RAW is the portable, unprivileged
 * stand-in and reflects the same kernel timekeeping path.) A guest whose TSC is trapped or
 * rescaled inconsistently shows a drifting ratio.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <time.h>
#include <math.h>
#include "../common/timing.h"

#define SAMPLES 2000
#define INTERVAL_NS 200000L  /* 0.2 ms */

static void pin0(void){ cpu_set_t s; CPU_ZERO(&s); CPU_SET(0,&s); sched_setaffinity(0,sizeof(s),&s);}
static long ns_of(struct timespec t){ return t.tv_sec*1000000000L + t.tv_nsec; }

int main(int argc, char **argv) {
    int json = 0; for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--json")) json = 1;
    pin0();
    double *ratio = malloc(SAMPLES * sizeof(double));
    int k = 0;
    for (int i = 0; i < SAMPLES; i++) {
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC_RAW, &a);
        uint64_t ta = rdtsc_start();
        long target = ns_of(a) + INTERVAL_NS;
        do { clock_gettime(CLOCK_MONOTONIC_RAW, &b); } while (ns_of(b) < target);
        uint64_t tb = rdtsc_end();
        long dns = ns_of(b) - ns_of(a);
        if (dns > 0) ratio[k++] = (double)(tb - ta) / (double)dns;  /* TSC cycles per ns */
    }
    double mean = 0; for (int i = 0; i < k; i++) mean += ratio[i]; mean /= k;
    double var = 0; for (int i = 0; i < k; i++){ double d = ratio[i]-mean; var += d*d; }
    double sd = sqrt(var / k), cv = mean > 0 ? sd/mean : 0;
    free(ratio);

    if (json)
        printf("{\"test\":\"hpet_tsc_ratio\",\"tsc_per_ns\":%.4f,\"ratio_stddev\":%.6f,"
               "\"ratio_cv\":%.6f,\"samples\":%d}\n", mean, sd, cv, k);
    else
        printf("timer coherence: %.3f TSC/ns, ratio stddev %.5f, cv %.5f (%d samples)\n",
               mean, sd, cv, k);
    return 0;
}

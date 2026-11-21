/*
 * Cross-vCPU TSC synchronization. Invariant TSC should read nearly identically across cores.
 * Two threads pinned to different CPUs repeatedly read the TSC; we estimate the per-core
 * offset by the minimum observed cross-read delta (minimum cancels most of the sampling gap).
 * A large or unstable offset (or TSC going backwards across cores) is a VM/timekeeping tell.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <unistd.h>
#include <pthread.h>
#include "../common/timing.h"
#include "../common/stats.h"

#define ITERS 20000
static int cpu_b = 1;
static volatile uint64_t t_other;
static volatile int ready;

static void pin(int c){ cpu_set_t s; CPU_ZERO(&s); CPU_SET(c,&s); sched_setaffinity(0,sizeof(s),&s);}

static void *peer(void *arg) {
    (void)arg; pin(cpu_b); ready = 1;
    for (;;) t_other = rdtsc_end();
    return NULL;
}

int main(int argc, char **argv) {
    int json = 0; for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--json")) json = 1;
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu < 2) {
        if (json) printf("{\"test\":\"tsc_sync\",\"skipped\":\"single vcpu\"}\n");
        else printf("tsc_sync: skipped (need >=2 vCPUs)\n");
        return 0;
    }
    pin(0);
    pthread_t th; pthread_create(&th, NULL, peer, NULL);
    while (!ready) sched_yield();

    uint64_t *absdiff = malloc(ITERS * sizeof(uint64_t));
    int64_t minsigned = INT64_MAX, maxsigned = INT64_MIN;
    for (int i = 0; i < ITERS; i++) {
        uint64_t a = rdtsc_end();
        uint64_t o = t_other;
        int64_t d = (int64_t)o - (int64_t)a;
        if (d < minsigned) minsigned = d;
        if (d > maxsigned) maxsigned = d;
        absdiff[i] = (uint64_t)(d < 0 ? -d : d);
    }
    pthread_cancel(th);
    struct stats s = compute_stats(absdiff, ITERS);
    free(absdiff);

    if (json)
        printf("{\"test\":\"tsc_sync\",\"min_abs_offset\":%lu,\"median_abs_offset\":%.1f,"
               "\"offset_spread\":%ld}\n",
               (unsigned long)s.min, s.median, (long)(maxsigned - minsigned));
    else
        printf("tsc_sync: min |offset| %lu cyc, median %.0f, spread %ld\n",
               (unsigned long)s.min, s.median, (long)(maxsigned - minsigned));
    return 0;
}

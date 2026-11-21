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
#include <stdatomic.h>
#include "../common/timing.h"
#include "../common/stats.h"

#define ITERS 20000
static int cpu_b = 1;
static _Atomic uint64_t t_other;
static atomic_int ready;
static atomic_int stop;
static atomic_int pin_error;

static int pin(int c) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(c, &s);
    return sched_setaffinity(0, sizeof(s), &s);
}

static void *peer(void *arg) {
    (void)arg;
    if (pin(cpu_b) != 0) {
        atomic_store_explicit(&pin_error, 1, memory_order_release);
        atomic_store_explicit(&ready, 1, memory_order_release);
        return NULL;
    }
    atomic_store_explicit(&ready, 1, memory_order_release);
    while (!atomic_load_explicit(&stop, memory_order_acquire))
        atomic_store_explicit(&t_other, rdtsc_end(), memory_order_release);
    return NULL;
}

int main(int argc, char **argv) {
    int json = 0;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--json")) json = 1;
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu < 2) {
        if (json) printf("{\"test\":\"tsc_sync\",\"skipped\":\"single vcpu\"}\n");
        else printf("tsc_sync: skipped (need >=2 vCPUs)\n");
        return 0;
    }
    if (pin(0) != 0) {
        fprintf(stderr, "tsc_sync: cannot pin to CPU 0 (check the allowed cpuset)\n");
        if (json) printf("{\"test\":\"tsc_sync\",\"error\":\"cannot pin to CPU 0\"}\n");
        return 1;
    }

    pthread_t th;
    int rc = pthread_create(&th, NULL, peer, NULL);
    if (rc != 0) {
        fprintf(stderr, "pthread_create: %s\n", strerror(rc));
        return 1;
    }
    while (!atomic_load_explicit(&ready, memory_order_acquire)) sched_yield();
    if (atomic_load_explicit(&pin_error, memory_order_acquire)) {
        pthread_join(th, NULL);
        fprintf(stderr, "tsc_sync: cannot pin peer to CPU 1 (check the allowed cpuset)\n");
        if (json) printf("{\"test\":\"tsc_sync\",\"error\":\"cannot pin to CPU 1\"}\n");
        return 1;
    }

    uint64_t *absdiff = malloc(ITERS * sizeof(uint64_t));
    if (!absdiff) {
        atomic_store(&stop, 1);
        pthread_join(th, NULL);
        return 1;
    }
    int64_t minsigned = INT64_MAX, maxsigned = INT64_MIN;
    for (int i = 0; i < ITERS; i++) {
        uint64_t a = rdtsc_end();
        uint64_t o = atomic_load_explicit(&t_other, memory_order_acquire);
        int64_t d = (int64_t)o - (int64_t)a;
        if (d < minsigned) minsigned = d;
        if (d > maxsigned) maxsigned = d;
        absdiff[i] = (uint64_t)(d < 0 ? -d : d);
    }
    atomic_store_explicit(&stop, 1, memory_order_release);
    pthread_join(th, NULL);
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

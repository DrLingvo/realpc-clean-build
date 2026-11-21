/*
 * Cache/memory latency via pointer chasing. Builds a randomized cyclic permutation over a
 * buffer of a given size and times dependent loads (each load's address depends on the
 * previous), defeating prefetch and OoO overlap. Reports per-access cycles for sizes that
 * land in L1/L2/L3/RAM. Under EPT/NPT a guest's cache latencies are close to native, so this
 * mostly characterizes the host; it is here to document, not to defeat, cache-timing probes.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include "../common/timing.h"

#define RUNS 400000

static void pin0(void){ cpu_set_t s; CPU_ZERO(&s); CPU_SET(0,&s); sched_setaffinity(0,sizeof(s),&s);}

static double chase(size_t bytes) {
    size_t n = bytes / sizeof(void *);
    if (n < 2) n = 2;
    void **buf = aligned_alloc(64, n * sizeof(void *));
    if (!buf) { perror("alloc"); exit(1); }
    size_t *idx = malloc(n * sizeof(size_t));
    for (size_t i = 0; i < n; i++) idx[i] = i;
    for (size_t i = n - 1; i > 0; i--) { size_t j = (size_t)rand() % (i + 1); size_t t = idx[i]; idx[i] = idx[j]; idx[j] = t; }
    for (size_t i = 0; i < n; i++) buf[idx[i]] = &buf[idx[(i + 1) % n]];
    free(idx);

    void **p = buf;
    for (int i = 0; i < 100000; i++) p = (void **)*p;        /* warm */
    uint64_t t0 = rdtsc_start();
    for (int i = 0; i < RUNS; i++) p = (void **)*p;
    uint64_t t1 = rdtsc_end();
    __asm__ __volatile__("" :: "r"(p) : "memory");
    free(buf);
    return (double)(t1 - t0) / RUNS;
}

int main(int argc, char **argv) {
    int json = 0; for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--json")) json = 1;
    pin0();
    double l1 = chase(16 * 1024);          /* 16 KiB  -> L1 */
    double l2 = chase(256 * 1024);         /* 256 KiB -> L2 */
    double l3 = chase(8 * 1024 * 1024);    /* 8 MiB   -> L3 */
    double ram = chase(256 * 1024 * 1024); /* 256 MiB -> RAM */
    if (json)
        printf("{\"test\":\"cache_latency\",\"l1_cycles\":%.2f,\"l2_cycles\":%.2f,"
               "\"l3_cycles\":%.2f,\"ram_cycles\":%.2f}\n", l1, l2, l3, ram);
    else
        printf("cache latency (cycles/access): L1 %.1f  L2 %.1f  L3 %.1f  RAM %.1f\n",
               l1, l2, l3, ram);
    return 0;
}

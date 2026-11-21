#ifndef TIMING_H
#define TIMING_H
/*
 * Low-level timing helpers for the detectability tests.
 *
 * Changes vs a naive rdtsc wrapper: the plain RDTSC can execute out of order with
 * respect to the code being measured, which smears the distribution. We serialize with
 * LFENCE before the opening read and use RDTSCP (which waits for prior instructions) for
 * the closing read. We also calibrate the TSC frequency so results can be reported in ns,
 * not just cycles (cycle thresholds are CPU-frequency dependent and not portable).
 */
#include <stdint.h>
#include <cpuid.h>
#include <time.h>

static inline uint64_t rdtsc_start(void) {
    uint32_t lo, hi;
    __asm__ __volatile__("lfence\n\trdtsc" : "=a"(lo), "=d"(hi) :: "memory");
    return ((uint64_t)hi << 32) | lo;
}

static inline uint64_t rdtsc_end(void) {
    uint32_t lo, hi, aux;
    __asm__ __volatile__("rdtscp\n\tlfence" : "=a"(lo), "=d"(hi), "=c"(aux) :: "memory");
    return ((uint64_t)hi << 32) | lo;
}

static inline void do_cpuid(uint32_t leaf, uint32_t subleaf,
                            uint32_t *eax, uint32_t *ebx, uint32_t *ecx, uint32_t *edx) {
    __cpuid_count(leaf, subleaf, *eax, *ebx, *ecx, *edx);
}

/* One VM-exit probe: CPUID is unconditionally intercepted by KVM, so on a guest this is a
 * full VM-exit/VM-entry; on bare metal it is just a (serializing) instruction. */
static inline uint64_t measure_cpuid_latency(void) {
    uint32_t a = 0, b, c = 0, d;
    uint64_t t1 = rdtsc_start();
    __cpuid_count(0, 0, a, b, c, d);
    uint64_t t2 = rdtsc_end();
    __asm__ __volatile__("" :: "r"(b), "r"(d) : "memory"); /* keep cpuid live */
    return t2 - t1;
}

/* Estimate TSC Hz by timing a fixed CLOCK_MONOTONIC interval. Good to ~0.1%. */
static inline double calibrate_tsc_hz(void) {
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    uint64_t t0 = rdtsc_start();
    /* busy-ish wait ~50 ms of monotonic time */
    do { clock_gettime(CLOCK_MONOTONIC, &b); } while (
        (b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec) < 50000000LL);
    uint64_t t1 = rdtsc_end();
    double ns = (double)((b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec));
    return (double)(t1 - t0) * 1e9 / ns;
}

#endif /* TIMING_H */

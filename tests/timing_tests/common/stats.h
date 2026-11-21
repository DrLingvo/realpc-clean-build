#ifndef STATS_H
#define STATS_H
#include <stdint.h>
#include <stddef.h>

struct stats {
    double   median;
    double   mean;
    double   p95;
    double   p99;
    double   stddev;
    double   cv;      /* coefficient of variation = stddev/mean (shape, CPU-freq independent) */
    uint64_t min;
    uint64_t max;
    size_t   n;
};

struct stats compute_stats(const uint64_t *data, size_t n);

#endif

#include "stats.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static double percentile(const uint64_t *sorted, size_t n, double p) {
    if (n == 0) return 0;
    double idx = p * (double)(n - 1);
    size_t lo = (size_t)idx, hi = lo + 1;
    if (hi >= n) return (double)sorted[n - 1];
    double frac = idx - (double)lo;
    return (double)sorted[lo] * (1.0 - frac) + (double)sorted[hi] * frac;
}

struct stats compute_stats(const uint64_t *data, size_t n) {
    struct stats s = {0};
    if (n == 0) return s;

    uint64_t *tmp = malloc(n * sizeof(uint64_t));
    if (!tmp) abort();
    memcpy(tmp, data, n * sizeof(uint64_t));
    qsort(tmp, n, sizeof(uint64_t), cmp_u64);

    s.n = n;
    s.min = tmp[0];
    s.max = tmp[n - 1];
    s.median = percentile(tmp, n, 0.50);
    s.p95 = percentile(tmp, n, 0.95);
    s.p99 = percentile(tmp, n, 0.99);

    double mean = 0;
    for (size_t i = 0; i < n; i++) mean += (double)tmp[i];
    mean /= (double)n;
    s.mean = mean;

    double var = 0;
    for (size_t i = 0; i < n; i++) {
        double d = (double)tmp[i] - mean;
        var += d * d;
    }
    s.stddev = sqrt(var / (double)n);
    s.cv = mean > 0 ? s.stddev / mean : 0;

    free(tmp);
    return s;
}

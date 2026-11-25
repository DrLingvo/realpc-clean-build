// Real hardware-event PMU probe. Build: cc -O2 -Wall -Wextra -o guest_pmu guest_pmu.c
// Run as root inside the guest. No counter values are generated or simulated.
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <linux/perf_event.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

struct counter_value {
    uint64_t value;
    uint64_t enabled;
    uint64_t running;
};

static volatile uint64_t sink;

static void workload(unsigned int iterations)
{
    uint64_t value = sink;
    for (unsigned int i = 0; i < iterations; i++)
        value = value * 6364136223846793005ULL + i + 1;
    sink = value;
}

static int open_counter(uint32_t type)
{
    struct perf_event_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.type = PERF_TYPE_HARDWARE;
    attr.config = type;
    attr.disabled = 1;
    attr.exclude_kernel = 1;
    attr.exclude_hv = 1;
    attr.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;
    return (int)syscall(SYS_perf_event_open, &attr, 0, -1, -1, 0);
}

static int measure(uint32_t type, unsigned int iterations, uint64_t *result)
{
    int fd = open_counter(type);
    struct counter_value value;
    if (fd < 0)
        return -1;
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) || ioctl(fd, PERF_EVENT_IOC_ENABLE, 0)) {
        close(fd);
        return -1;
    }
    workload(iterations);
    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0) ||
        read(fd, &value, sizeof(value)) != (ssize_t)sizeof(value)) {
        close(fd);
        return -1;
    }
    close(fd);
    if (!value.running || value.enabled < value.running) {
        errno = EIO;
        return -1;
    }
    // Scale only when the event was multiplexed; this is the kernel's measured schedule.
    *result = value.enabled == value.running ? value.value :
        (uint64_t)((__uint128_t)value.value * value.enabled / value.running);
    return 0;
}

static int cpuid_pmu(unsigned int *version, unsigned int *counters)
{
    unsigned int eax, ebx, ecx, edx;
    __asm__ volatile("cpuid" : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                     : "a"(0x0a), "c"(0));
    *version = eax & 0xff;
    *counters = (eax >> 8) & 0xff;
    return *version >= 2 && *counters > 0;
}

int main(void)
{
    const unsigned int low_iterations = 1000000;
    const unsigned int high_iterations = 20000000;
    const struct { uint32_t type; const char *name; } events[] = {
        { PERF_COUNT_HW_CPU_CYCLES, "cycles" },
        { PERF_COUNT_HW_INSTRUCTIONS, "instructions" },
    };
    uint64_t low[2], high[2];
    unsigned int version, counters;

    if (!cpuid_pmu(&version, &counters)) {
        fprintf(stderr, "FAIL: architectural PMU is absent (CPUID.0A version=%u counters=%u)\n",
                version, counters);
        return 2;
    }
    for (unsigned int i = 0; i < 2; i++) {
        if (measure(events[i].type, low_iterations, &low[i]) ||
            measure(events[i].type, high_iterations, &high[i])) {
            fprintf(stderr, "FAIL: %s perf event unavailable: %s\n",
                    events[i].name, strerror(errno));
            return 2;
        }
    }
    printf("{\"pmu_version\":%u,\"gp_counters\":%u,"
           "\"cycles_low\":%" PRIu64 ",\"cycles_high\":%" PRIu64 ","
           "\"instructions_low\":%" PRIu64 ",\"instructions_high\":%" PRIu64 "}\n",
           version, counters, low[0], high[0], low[1], high[1]);
    if (!low[0] || !high[0] || high[0] <= low[0]) {
        fprintf(stderr, "FAIL: cycles are zero or not load-dependent\n");
        return 1;
    }
    if (!low[1] || high[1] <= low[1] * 4) {
        fprintf(stderr, "FAIL: instructions are zero or not proportional to workload\n");
        return 1;
    }
    puts("PASS: real cycles and instructions increase with the measured workload");
    return 0;
}

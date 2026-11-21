CC      ?= gcc
CFLAGS  := -O2 -Wall -Wextra -std=gnu11 -Icommon
LDFLAGS := -lrt -lm -lpthread

TESTS := rdtsc_cpuid_rdtsc cache_latency tsc_sync hpet_tsc_ratio pmu_check rapl_check
BINS  := $(addprefix build/,$(TESTS))

.PHONY: all clean run

all: $(BINS)

build/%: tests/%.c common/stats.c common/timing.h common/stats.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $< common/stats.c $(LDFLAGS)

run: all
	@for t in $(TESTS); do \
		build/$$t --json > build/$$t.json 2>/dev/null || echo "{\"test\":\"$$t\",\"error\":true}" > build/$$t.json; \
		cat build/$$t.json; \
	done

clean:
	rm -rf build

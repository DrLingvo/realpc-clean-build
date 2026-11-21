CC      ?= gcc
CFLAGS  := -O2 -Wall -Wextra -std=gnu11 -Icommon
LDFLAGS := -lrt -lm -lpthread

TESTS := rdtsc_cpuid_rdtsc cache_latency tsc_sync hpet_tsc_ratio pmu_check rapl_check
BINS  := $(addprefix build/,$(TESTS))

.PHONY: all clean run test jitter-report

all: $(BINS)

build/%: tests/%.c common/stats.c common/timing.h common/stats.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $< common/stats.c $(LDFLAGS)

run: all
	@for t in $(TESTS); do \
		build/$$t --json > build/$$t.json 2> build/$$t.log; rc=$$?; \
		if [ "$$rc" -ne 0 ]; then \
			printf '{"test":"%s","error":"exit code %s; see %s.log"}\n' \
				"$$t" "$$rc" "$$t" > build/$$t.json; \
		fi; \
		cat build/$$t.json; \
	done

test:
	python3 -m unittest -v test_analyze.py

# Quantify the VM_EXIT_JITTER trade-off on a real sample (falls back to synthetic if the
# test can't run, e.g. off-target). Needs no patched kernel.
jitter-report: build/rdtsc_cpuid_rdtsc
	@build/rdtsc_cpuid_rdtsc --samples 20000 --dump-raw build/rdtsc_raw.bin >/dev/null 2>&1 \
		&& python3 jitter_report.py --raw build/rdtsc_raw.bin \
		|| python3 jitter_report.py

clean:
	rm -rf build

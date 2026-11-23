/*
 * Read-only host temperature and fan registers for the realpc ACPI profile.
 *
 * The device never forwards guest writes and never exposes host control MSRs.
 * Missing or invalid host readings return UINT32_MAX. ACPI provides a safe
 * fallback temperature and reports zero RPM for unavailable fans.
 */
#include "qemu/osdep.h"
#include "qemu/module.h"
#include "hw/isa/isa.h"

#include <fcntl.h>
#include <glob.h>
#include <unistd.h>

#define TYPE_HOST_SENSORS "host-sensors"
OBJECT_DECLARE_SIMPLE_TYPE(HostSensorsState, HOST_SENSORS)

#define HOST_SENSORS_PORT 0x610
#define HOST_SENSORS_SIZE 0x20
#define MSR_IA32_PACKAGE_THERM_STATUS 0x1b1
#define MSR_IA32_THERM_STATUS 0x19c
#define SENSOR_INVALID UINT32_MAX

struct HostSensorsState {
    ISADevice parent_obj;
    MemoryRegion io;
};

static bool read_text_u64(const char *path, uint64_t *value)
{
    char buf[64];
    char *end = NULL;
    int fd;
    ssize_t n;

    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) {
        return false;
    }
    buf[n] = '\0';
    errno = 0;
    *value = g_ascii_strtoull(buf, &end, 10);
    return errno == 0 && end != buf;
}

static bool read_cpu_msr(uint32_t msr, uint64_t *value)
{
    char path[64];
    int cpu = sched_getcpu();
    int fd;
    ssize_t n;

    if (cpu < 0) {
        cpu = 0;
    }
    snprintf(path, sizeof(path), "/dev/cpu/%d/msr", cpu);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    n = pread(fd, value, sizeof(*value), msr);
    close(fd);
    return n == (ssize_t)sizeof(*value);
}

static uint32_t intel_temperature(uint32_t msr)
{
    uint64_t status;
    int digital_readout;
    int tj_max = 100;

    if (!read_cpu_msr(msr, &status) || !(status & (1ULL << 31))) {
        return SENSOR_INVALID;
    }
    digital_readout = (status >> 16) & 0x7f;
    if (digital_readout < 0 || digital_readout > tj_max) {
        return SENSOR_INVALID;
    }
    /* ACPI _TMP uses tenths of kelvin. */
    return (uint32_t)((tj_max - digital_readout) * 10 + 2732);
}

static uint32_t thermal_zone_fallback(void)
{
    glob_t paths = {0};
    uint64_t millidegrees;
    uint32_t result = SENSOR_INVALID;
    size_t i;

    if (glob("/sys/class/thermal/thermal_zone*/temp", 0, NULL, &paths) != 0) {
        return result;
    }
    for (i = 0; i < paths.gl_pathc; i++) {
        if (read_text_u64(paths.gl_pathv[i], &millidegrees) &&
            millidegrees > 0 && millidegrees < 150000) {
            result = (uint32_t)(millidegrees / 100 + 2732);
            break;
        }
    }
    globfree(&paths);
    return result;
}

static uint32_t fan_rpm(unsigned wanted)
{
    glob_t paths = {0};
    uint64_t rpm;
    uint32_t result = SENSOR_INVALID;
    unsigned found = 0;
    size_t i;

    if (glob("/sys/class/hwmon/hwmon*/fan*_input", GLOB_NOSORT, NULL,
             &paths) != 0) {
        return result;
    }
    for (i = 0; i < paths.gl_pathc; i++) {
        if (!read_text_u64(paths.gl_pathv[i], &rpm) || rpm > 100000) {
            continue;
        }
        if (found == wanted) {
            result = (uint32_t)rpm;
            break;
        }
        found++;
    }
    globfree(&paths);
    return result;
}

static uint32_t sensor_voltage(void)
{
    glob_t paths = {0};
    uint64_t millivolts;
    uint32_t result = SENSOR_INVALID;
    size_t i;

    if (glob("/sys/class/hwmon/hwmon*/in*_input", 0, NULL, &paths) != 0) {
        return result;
    }
    for (i = 0; i < paths.gl_pathc; i++) {
        if (read_text_u64(paths.gl_pathv[i], &millivolts) &&
            millivolts > 0 && millivolts < 300000) {
            result = (uint32_t)millivolts;
            break;
        }
    }
    globfree(&paths);
    return result;
}

static uint32_t host_sensor_register(hwaddr offset)
{
    uint32_t value;

    switch (offset) {
    case 0x00:
        value = intel_temperature(MSR_IA32_PACKAGE_THERM_STATUS);
        return value == SENSOR_INVALID ? thermal_zone_fallback() : value;
    case 0x04:
        return intel_temperature(MSR_IA32_THERM_STATUS);
    case 0x08:
    case 0x0c:
    case 0x10:
    case 0x14:
        return fan_rpm((offset - 0x08) / 4);
    case 0x18:
        return sensor_voltage();
    case 0x1c: {
        uint32_t status = 0;
        if (host_sensor_register(0x00) != SENSOR_INVALID) {
            status |= 1;
        }
        if (host_sensor_register(0x04) != SENSOR_INVALID) {
            status |= 2;
        }
        if (fan_rpm(0) != SENSOR_INVALID) {
            status |= 4;
        }
        return status;
    }
    default:
        return SENSOR_INVALID;
    }
}

static uint64_t host_sensors_read(void *opaque, hwaddr offset, unsigned size)
{
    uint32_t base;
    if (offset >= HOST_SENSORS_SIZE || (offset & 3) || size > 4) {
        return UINT64_MAX;
    }
    base = host_sensor_register(offset);
    return base;
}

static void host_sensors_write(void *opaque, hwaddr offset, uint64_t value,
                               unsigned size)
{
    /* Read-only by design. */
}

static const MemoryRegionOps host_sensors_ops = {
    .read = host_sensors_read,
    .write = host_sensors_write,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 4,
        .unaligned = false,
    },
    .endianness = DEVICE_LITTLE_ENDIAN,
};

static void host_sensors_realize(DeviceState *dev, Error **errp)
{
    HostSensorsState *s = HOST_SENSORS(dev);

    memory_region_init_io(&s->io, OBJECT(s), &host_sensors_ops, s,
                          TYPE_HOST_SENSORS, HOST_SENSORS_SIZE);
    isa_register_ioport(ISA_DEVICE(dev), &s->io, HOST_SENSORS_PORT);
}

static void host_sensors_class_init(ObjectClass *oc, const void *data)
{
    DeviceClass *dc = DEVICE_CLASS(oc);

    dc->realize = host_sensors_realize;
    dc->desc = "Read-only host temperature and fan sensors";
}

static const TypeInfo host_sensors_info = {
    .name = TYPE_HOST_SENSORS,
    .parent = TYPE_ISA_DEVICE,
    .instance_size = sizeof(HostSensorsState),
    .class_init = host_sensors_class_init,
};

static void host_sensors_register_types(void)
{
    type_register_static(&host_sensors_info);
}

type_init(host_sensors_register_types);

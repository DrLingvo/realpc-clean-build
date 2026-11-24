#!/usr/bin/env python3
"""Generate a consistent, randomized hardware profile for the VM.

Everyone who uses the stock defaults shares one fingerprint (same board, memory, serials).
This produces a *self-consistent* random profile — the socket, memory type, speed, voltage,
form factor, CPU, board, BIOS vendor and serials all agree with one real platform — so a VM
does not stand out either by matching the crowd or by mixing incompatible parts (the DDR3-on-
LGA1700 kind of tell).

Two outputs, because the SMBIOS story is split across build time and run time:
  * profile.env  — values compiled into QEMU (memory TYPE and FORM FACTOR, voltages, socket,
                   disk serial prefix, battery/PSU). Apply by rebuilding with it merged into
                   config.env. Only needed when the profile's memory type/form factor differ
                   from the build you already have.
  * profile.args — the per-VM `args:` line (-smbios type 0/1/2/3/4/17, -cpu ...). Works with
                   any build, no rebuild. Sets board/BIOS/CPU strings and the type-17
                   manufacturer/part/speed/serial (memory TYPE byte and FORM FACTOR are not
                   settable via -smbios, hence profile.env).

usage: gen-profile.py [--platform P] [--kind gaming|neutral] [--seed N] [--out DIR] [--host-sensors 0|1]
       gen-profile.py --list
Platforms: intel_desktop_lga1700, intel_desktop_lga1200, amd_desktop_am5, amd_desktop_am4,
           intel_laptop, server  (omit --platform to pick at random)
"""
import argparse
import json
import random
import shlex
import subprocess
import sys
import uuid

# memory_type byte (SMBIOS 7.18.2): DDR3=0x18 DDR4=0x1a DDR5=0x22
# form_factor (7.18.1): DIMM=0x09 SODIMM=0x0d
DIMM, SODIMM = 0x09, 0x0D

# Memory classes tie the type byte, form factor, voltage and kits together, and each kit is
# (vendor, part, speed) so vendor/part/speed/form all agree (no Kingston part under a Corsair
# label, no DIMM part on a SODIMM board, no 3200 part clocked at 3600).
MEM_CLASS = {
    "ddr4_dimm": (0x1A, DIMM, 1200, [
        ("Kingston", "KF432C16BB/16", 3200), ("Corsair", "CMK16GX4M2B3200C16", 3200),
        ("G.Skill", "F4-3600C16-16GVKC", 3600), ("Crucial", "BL16G32C16U4B", 3200)]),
    "ddr5_dimm": (0x22, DIMM, 1100, [
        ("Kingston", "KF556C40BB-16", 5600), ("Corsair", "CMK32GX5M2B5600C36", 5600),
        ("G.Skill", "F5-6000J3038F16G", 6000), ("Crucial", "CT16G52C42U5", 5200)]),
    "ddr5_sodimm": (0x22, SODIMM, 1100, [
        ("Crucial", "CT16G56C46S5", 5600), ("Kingston", "KF556S40-16", 5600),
        ("Samsung", "M425R2GA3BB0-CQK", 4800), ("SK Hynix", "HMCG78AGBSA095N", 5600)]),
    "ddr4_rdimm": (0x1A, DIMM, 1200, [
        ("Samsung", "M393A2K40DB3-CWE", 3200), ("Micron", "MTA18ASF2G72PDZ-3G2", 3200),
        ("SK Hynix", "HMA82GR7DJR8N-XN", 3200)]),
}
FF_NAME = {DIMM: "DIMM", SODIMM: "SODIMM"}

# board maker -> PCI subsystem vendor id (for STRONG_SUBSYS_IDS, so onboard devices carry the
# board's id instead of 0x1af4 Red Hat)
SUBSYS_VENDOR = {
    "ASUSTeK COMPUTER INC.": 0x1043, "Micro-Star International Co., Ltd.": 0x1462,
    "Gigabyte Technology Co., Ltd.": 0x1458, "Maxsun": 0x1462, "LENOVO": 0x17AA,
    "Dell Inc.": 0x1028, "HP": 0x103C, "Supermicro": 0x15D9,
}

AMI = "American Megatrends International, LLC."

# Nominal base frequency (Hz) per CPU model, matched by substring of the model string.
# This is the frequency a detector expects from CPUID.16H / the model's spec sheet, and the
# rate the invariant TSC ticks at on that part. Used only when --tsc-pin is set, to make the
# reported/measured TSC frequency agree with the CPU we claim in SMBIOS. Values are the
# advertised base clocks (Intel ARK / AMD spec).
CPU_BASE_HZ = {
    "i5-12400": 2_500_000_000, "i5-13400": 2_500_000_000,
    "i7-12700K": 3_600_000_000, "i7-13700K": 3_400_000_000,
    "i5-10400": 2_900_000_000, "i5-11400": 2_600_000_000,
    "i7-10700K": 3_800_000_000, "i7-11700K": 3_600_000_000,
    "i5-1240P": 1_700_000_000, "i7-1355U": 1_700_000_000,
    "i7-12700H": 2_300_000_000, "i7-13700H": 2_400_000_000,
    "Ryzen 5 7600": 3_800_000_000, "Ryzen 7 7700": 3_800_000_000,
    "Ryzen 7 7800X3D": 4_200_000_000, "Ryzen 9 7900X": 4_700_000_000,
    "Ryzen 5 5600G": 3_900_000_000, "Ryzen 5 5600": 3_500_000_000,
    "Ryzen 7 5800X": 3_800_000_000, "Ryzen 7 5700X": 3_400_000_000,
    "Silver 4314": 2_400_000_000, "Gold 5318Y": 2_100_000_000, "Gold 6338": 2_000_000_000,
}


def cpu_base_hz(cpu_name):
    # longest key first so "Ryzen 5 5600G" wins over "Ryzen 5 5600"
    for key in sorted(CPU_BASE_HZ, key=len, reverse=True):
        if key in cpu_name:
            return CPU_BASE_HZ[key]
    return None

PLATFORMS = {
    "intel_desktop_lga1700": {
        "socket": "LGA1700", "mem_class": "ddr4_dimm", "cpu_vendor": "Intel(R) Corporation",
        "cpus_neutral": ["12th Gen Intel(R) Core(TM) i5-12400",
                         "13th Gen Intel(R) Core(TM) i5-13400"],
        "cpus_gaming": ["12th Gen Intel(R) Core(TM) i7-12700K",
                        "13th Gen Intel(R) Core(TM) i7-13700K"],
        "boards": [("Micro-Star International Co., Ltd.", "PRO B760M-P"),
                   ("ASUSTeK COMPUTER INC.", "PRIME B760M-A"),
                   ("Gigabyte Technology Co., Ltd.", "B760M DS3H"),
                   ("Maxsun", "MS-Terminator B760M")],
        "chassis": 3, "bios_vendor": AMI, "oui": ["2C:F0:5D", "04:D4:C4", "00:D8:61"],
    },
    "intel_desktop_lga1200": {
        "socket": "LGA1200", "mem_class": "ddr4_dimm", "cpu_vendor": "Intel(R) Corporation",
        "cpus_neutral": ["Intel(R) Core(TM) i5-10400", "Intel(R) Core(TM) i5-11400"],
        "cpus_gaming": ["Intel(R) Core(TM) i7-10700K", "Intel(R) Core(TM) i7-11700K"],
        "boards": [("ASUSTeK COMPUTER INC.", "PRIME B560M-A"),
                   ("Micro-Star International Co., Ltd.", "B560M PRO-VDH"),
                   ("Gigabyte Technology Co., Ltd.", "B560M DS3H")],
        "chassis": 3, "bios_vendor": AMI, "oui": ["2C:F0:5D", "04:D4:C4"],
    },
    "amd_desktop_am5": {
        "socket": "AM5", "mem_class": "ddr5_dimm", "cpu_vendor": "Advanced Micro Devices, Inc.",
        "cpus_neutral": ["AMD Ryzen 5 7600 6-Core Processor",
                         "AMD Ryzen 7 7700 8-Core Processor"],
        "cpus_gaming": ["AMD Ryzen 7 7800X3D 8-Core Processor",
                        "AMD Ryzen 9 7900X 12-Core Processor"],
        "boards": [("ASUSTeK COMPUTER INC.", "TUF GAMING B650-PLUS"),
                   ("Micro-Star International Co., Ltd.", "MAG B650 TOMAHAWK WIFI"),
                   ("Gigabyte Technology Co., Ltd.", "B650 AORUS ELITE AX")],
        "chassis": 3, "bios_vendor": AMI, "oui": ["04:D4:C4", "2C:F0:5D", "A8:5E:45"],
    },
    "amd_desktop_am4": {
        "socket": "AM4", "mem_class": "ddr4_dimm", "cpu_vendor": "Advanced Micro Devices, Inc.",
        "cpus_neutral": ["AMD Ryzen 5 5600 6-Core Processor",
                         "AMD Ryzen 5 5600G with Radeon Graphics"],
        "cpus_gaming": ["AMD Ryzen 7 5800X 8-Core Processor",
                        "AMD Ryzen 7 5700X 8-Core Processor"],
        "boards": [("ASUSTeK COMPUTER INC.", "TUF GAMING B550-PLUS"),
                   ("Micro-Star International Co., Ltd.", "B550-A PRO"),
                   ("Gigabyte Technology Co., Ltd.", "B550 AORUS ELITE V2")],
        "chassis": 3, "bios_vendor": AMI, "oui": ["04:D4:C4", "2C:F0:5D"],
    },
    "intel_laptop": {
        "socket": "BGA1744", "mem_class": "ddr5_sodimm", "cpu_vendor": "Intel(R) Corporation",
        "cpus_neutral": ["12th Gen Intel(R) Core(TM) i5-1240P",
                         "13th Gen Intel(R) Core(TM) i7-1355U"],
        "cpus_gaming": ["12th Gen Intel(R) Core(TM) i7-12700H",
                        "13th Gen Intel(R) Core(TM) i7-13700H"],
        "boards": [("LENOVO", "20U9"), ("Dell Inc.", "0K3WPT"), ("HP", "8A78")],
        "chassis": 10, "bios_vendor_oem": True,
        "bios_vendors": ["LENOVO", "Dell Inc.", "Insyde Corp."],
        "oui": ["8C:16:45", "E8:6F:38", "B0:22:7A"],
    },
    "server": {
        "socket": "LGA4189", "mem_class": "ddr4_rdimm", "cpu_vendor": "Intel(R) Corporation",
        "cpus_neutral": ["Intel(R) Xeon(R) Silver 4314 CPU @ 2.40GHz",
                         "Intel(R) Xeon(R) Gold 5318Y CPU @ 2.10GHz"],
        "cpus_gaming": ["Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"],
        "boards": [("Supermicro", "X12DPi-N6"), ("Dell Inc.", "0H5J3T")],
        "chassis": 23, "bios_vendor": AMI, "oui": ["3C:EC:EF", "B4:96:91"],
    },
}

def rnd_hex(n):
    return "".join(random.choice("0123456789ABCDEF") for _ in range(n))


def rnd_digits(n):
    return "".join(random.choice("0123456789") for _ in range(n))


def rnd_alnum(n):
    return "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789") for _ in range(n))


def detect_host_vendor(path="/proc/cpuinfo"):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("vendor_id") and ":" in line:
                    return {"GenuineIntel": "intel", "AuthenticAMD": "amd"}.get(
                        line.split(":", 1)[1].strip(), "unknown")
    except OSError:
        pass
    return "unknown"


def platform_vendor(platform):
    return "intel" if PLATFORMS[platform]["cpu_vendor"].startswith("Intel") else "amd"


def detect_host_cpu_model(path="/proc/cpuinfo"):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("model name") and ":" in line:
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return None


def detect_host_socket():
    """Read the physical socket from SMBIOS; never infer it from a CPU SKU."""
    try:
        result = subprocess.run(["dmidecode", "-t", "processor"], check=True,
                                capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    for line in result.stdout.splitlines():
        if line.strip().startswith("Socket Designation:"):
            value = line.split(":", 1)[1].strip().upper().replace(" ", "")
            aliases = {"LGA1151": "LGA1151", "LGA1200": "LGA1200",
                       "LGA1700": "LGA1700", "LGA4189": "LGA4189",
                       "SOCKETAM4": "AM4", "SOCKETAM5": "AM5"}
            return aliases.get(value, value)
    return None


def gen(platform, kind, host_sensors, pmu=True, tsc_pin=False, host_vendor="unknown",
        cpu_source="host", host_cpu_model=None, cpu_model=None):
    p = PLATFORMS[platform]
    if host_vendor != "unknown" and host_vendor != platform_vendor(platform):
        raise ValueError(f"platform {platform} does not match {host_vendor} host CPU")
    if cpu_source not in ("host", "model"):
        raise ValueError("cpu_source must be 'host' or 'model'")
    mem_type, mem_form, mem_volt, kits = MEM_CLASS[p["mem_class"]]
    cpus = p["cpus_gaming"] if kind == "gaming" else p["cpus_neutral"]
    if cpu_source == "host":
        if not host_cpu_model or not host_cpu_model.strip():
            raise ValueError("Strong-real requires the exact host CPU model")
        cpu = host_cpu_model.strip()
        if cpu_model is not None:
            raise ValueError("an arbitrary CPU model is forbidden when cpu_source=host")
    else:
        cpu = cpu_model.strip() if cpu_model else random.choice(cpus)
        if not cpu or any(ord(c) < 32 for c in cpu):
            raise ValueError("model mode requires a printable, non-empty CPU SKU")
    board_vendor, board_model = random.choice(p["boards"])
    mem_vendor, mem_part, speed = random.choice(kits)
    serial17 = rnd_hex(8)
    asset17 = rnd_digits(10)
    board_serial = rnd_alnum(10)
    sys_uuid = str(uuid.UUID(int=random.getrandbits(128), version=4))
    oui = random.choice(p["oui"])
    mac = oui + ":" + ":".join(rnd_hex(2) for _ in range(3))
    bios_ver = f"{random.randint(1,3)}.{random.randint(10,80)}"
    bios_date = f"{random.randint(1,12):02d}/{random.randint(1,28):02d}/{random.randint(2022,2024)}"
    if p.get("bios_vendor_oem"):
        bios_vendor = random.choice(p["bios_vendors"])
    else:
        bios_vendor = p["bios_vendor"]

    env = {
        "MEM_TYPE_HEX": f"0x{mem_type:02x}",
        "MEM_FORM_FACTOR_HEX": f"0x{mem_form:02x}",
        "MEM_SPEED": str(speed),
        "MEM_VENDOR": mem_vendor,
        "MEM_PART": mem_part,
        "MEM_VMIN": str(mem_volt),
        "MEM_VMAX": str(mem_volt),
        "MEM_VCFG": str(mem_volt),
        "CPU_SOCKET": p["socket"],
        "SUBSYS_VENDOR_HEX": f"0x{SUBSYS_VENDOR.get(board_vendor, 0x1043):04x}",
        "SUBSYS_DEVICE_HEX": f"0x{random.randint(0x8000, 0x8fff):04x}",
    }

    # -cpu options: a real CPU exposes an architectural PMU (CPUID.0AH) and a fixed TSC
    # frequency. pmu=on turns on KVM's in-guest PMU so CPUID.0AH is non-zero (its absence is
    # a VM tell). tsc-frequency pins the reported/measured TSC rate to the claimed model's
    # base clock (opt-in; see the warning in main()).
    cpu_opts = ["host", "host-cache-info=on", "hypervisor=off",
                "vmware-cpuid-freq=false", "enforce=false", "host-phys-bits=true"]
    if pmu:
        cpu_opts.append("pmu=on")
    tsc_hz = cpu_base_hz(cpu) if tsc_pin else None
    if tsc_pin and tsc_hz:
        cpu_opts.append(f"tsc-frequency={tsc_hz}")
    if host_sensors and host_vendor == "intel":
        cpu_opts.append("host-sensors=on")
    args = (
        "-cpu " + ",".join(cpu_opts) + " "
        f'-smbios type=0,vendor="{bios_vendor}",version={bios_ver},date={bios_date},release={bios_ver} '
        f'-smbios type=1,manufacturer="{board_vendor}",product="{board_model}",version="1.0",serial={board_serial},uuid={sys_uuid} '
        f'-smbios type=2,manufacturer="{board_vendor}",product="{board_model}",version="1.0",serial={board_serial} '
        f'-smbios type=3,manufacturer="{board_vendor}",type={p["chassis"]},version="1.0" '
        f'-smbios type=4,manufacturer="{p["cpu_vendor"]}",version="{cpu}" '
        f'-smbios type=17,manufacturer="{mem_vendor}",part="{mem_part}",speed={speed},serial={serial17},asset={asset17} '
        "-smbios type=9 -smbios type=8"
    )
    summary = {
        "platform": platform, "kind": kind, "cpu_source": cpu_source,
        "cpu": cpu, "host_vendor": host_vendor,
        "board": f"{board_vendor} {board_model}", "socket": p["socket"],
        "memory": f"{mem_vendor} {mem_part} @ {speed} MT/s (type 0x{mem_type:02x}, {FF_NAME[mem_form]})",
        "bios": f"{bios_vendor} {bios_ver} ({bios_date})", "mac": mac, "uuid": sys_uuid,
        "pmu": "on" if pmu else "off",
        "tsc": (f"pinned {tsc_hz/1e9:.2f} GHz" if (tsc_pin and tsc_hz)
                else ("host (not pinned)" if not tsc_pin
                      else "host (no base-freq known for this model)")),
    }
    return env, args, summary, (mem_type, mem_form), (tsc_pin and tsc_hz is not None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=list(PLATFORMS))
    ap.add_argument("--kind", choices=["gaming", "neutral"], default="neutral")
    ap.add_argument("--cpu-source", choices=["host", "model"], default="host",
                    help="host: exact host CPU identity; model: Strong-skin skeleton")
    ap.add_argument("--cpu-model", help="SKU for --cpu-source model; forbidden in host mode")
    ap.add_argument("--host-cpu-model", help=argparse.SUPPRESS)
    ap.add_argument("--socket", help="physical host socket; default: dmidecode")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--vmid", help="stable VM identifier recorded in profile.conf")
    ap.add_argument("--out", default=".")
    ap.add_argument("--host-sensors", type=int, choices=[0, 1], default=1)
    ap.add_argument("--host-vendor", choices=["auto", "intel", "amd", "unknown"], default="auto",
                    help="real host CPU vendor; auto reads /proc/cpuinfo and prevents a "
                         "profile for the other vendor")
    ap.add_argument("--pmu", type=int, choices=[0, 1], default=1,
                    help="expose an architectural PMU to the guest (default on; its absence "
                         "is a VM tell)")
    ap.add_argument("--tsc-pin", type=int, choices=[0, 1], default=0,
                    help="pin tsc-frequency to the claimed CPU's base clock (default off; "
                         "needs host hardware TSC scaling and breaks live migration)")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        for k, v in PLATFORMS.items():
            mt, mf, _, _ = MEM_CLASS[v["mem_class"]]
            print(f"{k:24s} socket={v['socket']:9s} mem=0x{mt:02x} {FF_NAME[mf]}")
        return
    if a.seed is not None:
        random.seed(a.seed)
    host_vendor = detect_host_vendor() if a.host_vendor == "auto" else a.host_vendor
    host_cpu_model = (a.host_cpu_model or detect_host_cpu_model()
                      if a.cpu_source == "host" else None)
    if host_vendor == "unknown" and not a.platform:
        ap.error("cannot detect the host CPU vendor; specify --platform and --host-vendor explicitly")
    if a.cpu_source == "host" and not host_cpu_model:
        ap.error("cannot read the host CPU model from /proc/cpuinfo")
    socket = a.socket or (detect_host_socket() if a.cpu_source == "host" else None)
    compatible = [name for name in PLATFORMS
                  if (host_vendor == "unknown" or platform_vendor(name) == host_vendor)
                  and (not socket or PLATFORMS[name]["socket"].upper() == socket.upper())]
    if not compatible:
        ap.error(f"no platform matches host vendor {host_vendor} and socket {socket or 'unknown'}")
    if not a.platform and a.cpu_source == "host" and not socket:
        ap.error("cannot detect the host socket; pass --socket explicitly (do not guess it)")
    platform = a.platform or random.choice(compatible)
    if platform not in compatible:
        ap.error(f"platform {platform} does not match host vendor {host_vendor} and socket {socket or 'unknown'}")
    env, args, summary, (mem_type, mem_form), tsc_pinned = gen(
        platform, a.kind, a.host_sensors, pmu=bool(a.pmu), tsc_pin=bool(a.tsc_pin),
        host_vendor=host_vendor, cpu_source=a.cpu_source,
        host_cpu_model=host_cpu_model, cpu_model=a.cpu_model)

    import os
    os.makedirs(a.out, exist_ok=True)
    envp = os.path.join(a.out, "profile.env")
    argp = os.path.join(a.out, "profile.args")
    confp = os.path.join(a.out, "profile.conf")
    jsonp = os.path.join(a.out, "profile.json")
    with open(envp, "w") as f:
        f.write("# Build-time profile overrides. Merge into config.env and rebuild QEMU if the\n")
        f.write("# memory type/form factor below differ from your build, or to apply the subsystem\n")
        f.write("# ids (those need STRONG_SUBSYS_IDS=1 in config.env).\n")
        for k, v in env.items():
            f.write(f'{k}="{v}"\n' if " " in v else f"{k}={v}\n")
    with open(argp, "w") as f:
        f.write("args: " + args + "\n")
    with open(confp, "w") as f:
        for key, value in summary.items():
            if isinstance(value, (str, int)):
                f.write(f"{key.upper()}={shlex.quote(str(value))}\n")
        f.write(f"CPU_ARGS={shlex.quote(args)}\n")
    if a.vmid:
        summary["vmid"] = a.vmid
    with open(jsonp, "w") as f:
        json.dump({"summary": summary, "env": env, "args": args}, f,
                  indent=2, sort_keys=True)
        f.write("\n")

    print(f"Platform: {summary['platform']} ({summary['kind']}, {a.cpu_source})")
    for key in ("host_vendor", "cpu", "board", "socket", "memory", "bios", "mac", "pmu", "tsc"):
        print(f"  {key:8s}: {summary[key]}")
    print(f"\nwrote {envp}, {argp}, {confp} and {jsonp}")
    if tsc_pinned:
        print(
            "\n!! tsc-frequency is PINNED. Two requirements before you use this profile:\n"
            "   1. The host must support hardware TSC scaling, OR its real TSC must already\n"
            "      equal the pinned value. Otherwise KVM traps every RDTSC in the guest,\n"
            "      which is slow AND far more detectable than leaving TSC unpinned.\n"
            "      Check:  dmesg | grep -i 'tsc.*scal'   and   check host CPUID for the\n"
            "      VMX TSC-scaling control (Intel: Skylake-SP+/some client; AMD: Zen+).\n"
            "   2. Live migration to a host with a different TSC rate is NOT supported.\n"
            "   If either is a problem, regenerate without --tsc-pin (the default).")
    elif a.tsc_pin:
        print("\nNote: --tsc-pin was set but this CPU model has no known base clock in\n"
              "      CPU_BASE_HZ, so tsc-frequency was left unpinned (host TSC is used).")
    default_mem = (mem_type == 0x1A and mem_form == DIMM)
    if default_mem:
        print("Memory matches the committed DDR4/DIMM default — profile.args alone is enough "
              "(no rebuild).")
    else:
        print("Memory differs from the committed default — rebuild QEMU with profile.env merged "
              "into config.env for a consistent type-17.")


if __name__ == "__main__":
    main()

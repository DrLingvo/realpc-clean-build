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
import random
import sys

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

AMI = "American Megatrends International, LLC."

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


def gen(platform, kind, host_sensors):
    p = PLATFORMS[platform]
    mem_type, mem_form, mem_volt, kits = MEM_CLASS[p["mem_class"]]
    cpus = p["cpus_gaming"] if kind == "gaming" else p["cpus_neutral"]
    cpu = random.choice(cpus)
    board_vendor, board_model = random.choice(p["boards"])
    mem_vendor, mem_part, speed = random.choice(kits)
    serial17 = rnd_hex(8)
    asset17 = rnd_digits(10)
    board_serial = rnd_alnum(10)
    sys_uuid = f"{rnd_hex(8)}-{rnd_hex(4)}-{rnd_hex(4)}-{rnd_hex(4)}-{rnd_hex(12)}".lower()
    # disk serial prefix styled after a real drive family (SSD/NVMe)
    ide_prefix = random.choice(["S4EVNF0N", "S6Z1NG0T", "50026B7", "Z9ANESAM"])[:6] + rnd_alnum(2)
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
        "IDE_SERIAL_PREFIX": ide_prefix,
    }

    hs = ",host-sensors=on" if host_sensors and p["cpu_vendor"].startswith("Intel") else ""
    args = (
        "-cpu host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,"
        f"enforce=false,host-phys-bits=true{hs} "
        f'-smbios type=0,vendor="{bios_vendor}",version={bios_ver},date={bios_date},release={bios_ver} '
        f'-smbios type=1,manufacturer="{board_vendor}",product="{board_model}",version="1.0",serial={board_serial},uuid={sys_uuid} '
        f'-smbios type=2,manufacturer="{board_vendor}",product="{board_model}",version="1.0",serial={board_serial} '
        f'-smbios type=3,manufacturer="{board_vendor}",type={p["chassis"]},version="1.0" '
        f'-smbios type=4,manufacturer="{p["cpu_vendor"]}",version="{cpu}" '
        f'-smbios type=17,manufacturer="{mem_vendor}",part="{mem_part}",speed={speed},serial={serial17},asset={asset17} '
        "-smbios type=9 -smbios type=8"
    )
    summary = {
        "platform": platform, "kind": kind, "cpu": cpu,
        "board": f"{board_vendor} {board_model}", "socket": p["socket"],
        "memory": f"{mem_vendor} {mem_part} @ {speed} MT/s (type 0x{mem_type:02x}, {FF_NAME[mem_form]})",
        "bios": f"{bios_vendor} {bios_ver} ({bios_date})", "mac": mac, "uuid": sys_uuid,
    }
    return env, args, summary, (mem_type, mem_form)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--platform", choices=list(PLATFORMS))
    ap.add_argument("--kind", choices=["gaming", "neutral"], default="neutral")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--out", default=".")
    ap.add_argument("--host-sensors", type=int, default=1)
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        for k, v in PLATFORMS.items():
            mt, mf, _, _ = MEM_CLASS[v["mem_class"]]
            print(f"{k:24s} socket={v['socket']:9s} mem=0x{mt:02x} {FF_NAME[mf]}")
        return
    if a.seed is not None:
        random.seed(a.seed)
    platform = a.platform or random.choice(list(PLATFORMS))
    env, args, summary, (mem_type, mem_form) = gen(platform, a.kind, a.host_sensors)

    import os
    os.makedirs(a.out, exist_ok=True)
    envp = os.path.join(a.out, "profile.env")
    argp = os.path.join(a.out, "profile.args")
    with open(envp, "w") as f:
        f.write("# Build-time profile overrides. Merge into config.env and rebuild QEMU ONLY if\n")
        f.write("# the memory type/form factor below differ from your current build.\n")
        for k, v in env.items():
            f.write(f'{k}="{v}"\n' if " " in v else f"{k}={v}\n")
    with open(argp, "w") as f:
        f.write("args: " + args + "\n")

    print(f"Platform: {summary['platform']} ({summary['kind']})")
    for key in ("cpu", "board", "socket", "memory", "bios", "mac"):
        print(f"  {key:8s}: {summary[key]}")
    print(f"\nwrote {envp} and {argp}")
    default_mem = (mem_type == 0x1A and mem_form == DIMM)
    if default_mem:
        print("Memory matches the committed DDR4/DIMM default — profile.args alone is enough "
              "(no rebuild).")
    else:
        print("Memory differs from the committed default — rebuild QEMU with profile.env merged "
              "into config.env for a consistent type-17.")


if __name__ == "__main__":
    main()

/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20230628 (64-bit version)
 * Copyright (c) 2000 - 2023 Intel Corporation
 * 
 * Disassembling to symbolic ASL+ operators
 *
 * Disassembly of ssdt-ec.aml, Fri Nov 20 15:58:50 2026
 *
 * Original Table Header:
 *     Signature        "SSDT"
 *     Length           0x0000007A (122)
 *     Revision         0x02
 *     Checksum         0x63
 *     OEM ID           "ACDT"
 *     OEM Table ID     "SsdtEC"
 *     OEM Revision     0x00001000 (4096)
 *     Compiler ID      "INTL"
 *     Compiler Version 0x20250404 (539296772)
 */
DefinitionBlock ("", "SSDT", 2, "ACDT", "SsdtEC", 0x00001000)
{
    External (_SB_.PCI0, DeviceObj)

    Scope (\_SB)
    {
        Scope (\_SB.PCI0)
        {
            Device (EC)
            {
                Name (_HID, "ACID0001")  // _HID: Hardware ID
                Method (_STA, 0, NotSerialized)  // _STA: Status
                {
                    If (_OSI ("macos"))
                    {
                        Return (0x0F)
                    }
                    Else
                    {
                        Return (0x0F)
                    }
                }
            }
        }
    }
}


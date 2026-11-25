DefinitionBlock ("", "SSDT", 2, "ALASKA", "A M I   ", 0x00000001)
{
    Scope (\_SB)
    {
        Device (HSEN)
        {
            Name (_HID, EisaId ("PNP0C02"))
            Name (_UID, "HWMON")
            Name (_STA, 0x0F)
            Name (_CRS, ResourceTemplate ()
            {
                IO (Decode16, 0x0610, 0x0610, 0x01, 0x20)
            })
            OperationRegion (HSIO, SystemIO, 0x0610, 0x20)
            Field (HSIO, DWordAcc, NoLock, Preserve)
            {
                TPCK,   32,
                TPCR,   32,
                FAN0,   32,
                FAN1,   32,
                FAN2,   32,
                FAN3,   32,
                VOLT,   32,
                STAT,   32
            }
        }
    }

    Scope (\_TZ)
    {
        Device (FAN0)
        {
            Name (_HID, EisaId ("PNP0C0B"))
            Name (_UID, "CPU-FAN")
            Name (_FIF, Package (0x04) { Zero, 0x32, 0x02, Zero })
            Method (_FST, 0, NotSerialized)
            {
                Local0 = \_SB.HSEN.FAN0
                If (Local0 == 0xFFFFFFFF) { Local0 = Zero }
                Local1 = Package (0x03) { Zero, 0x32, Zero }
                Local1 [0x02] = Local0
                Return (Local1)
            }
        }

        Device (FAN1)
        {
            Name (_HID, EisaId ("PNP0C0B"))
            Name (_UID, "SYS-FAN")
            Name (_FIF, Package (0x04) { Zero, 0x32, 0x02, Zero })
            Method (_FST, 0, NotSerialized)
            {
                Local0 = \_SB.HSEN.FAN1
                If (Local0 == 0xFFFFFFFF) { Local0 = Zero }
                Local1 = Package (0x03) { Zero, 0x32, Zero }
                Local1 [0x02] = Local0
                Return (Local1)
            }
        }

        ThermalZone (TZ00)
        {
            Method (_TMP, 0, NotSerialized)
            {
                Local0 = \_SB.HSEN.TPCK
                If (Local0 == 0xFFFFFFFF) { Return (0x0BB8) }
                Return (Local0)
            }
            Method (_PSV, 0, NotSerialized) { Return (0x1058) }
            Method (_HOT, 0, NotSerialized) { Return (0x106C) }
            Method (_CRT, 0, NotSerialized) { Return (0x1076) }
            Method (_TC1, 0, NotSerialized) { Return (0x02) }
            Method (_TC2, 0, NotSerialized) { Return (0x05) }
            Method (_TSP, 0, NotSerialized) { Return (0x0A) }
            Method (_TZP, 0, NotSerialized) { Return (0x012C) }
            Name (_AL0, Package (0x01) { FAN0 })
        }

        ThermalZone (TZ01)
        {
            Method (_TMP, 0, NotSerialized)
            {
                Local0 = \_SB.HSEN.TPCR
                If (Local0 == 0xFFFFFFFF) { Return (0x0BB8) }
                Return (Local0)
            }
            Method (_PSV, 0, NotSerialized) { Return (0x1058) }
            Method (_HOT, 0, NotSerialized) { Return (0x106C) }
            Method (_CRT, 0, NotSerialized) { Return (0x1076) }
            Method (_TC1, 0, NotSerialized) { Return (0x02) }
            Method (_TC2, 0, NotSerialized) { Return (0x05) }
            Method (_TSP, 0, NotSerialized) { Return (0x0A) }
            Method (_TZP, 0, NotSerialized) { Return (0x012C) }
            Name (_AL1, Package (0x01) { FAN1 })
        }
    }
}

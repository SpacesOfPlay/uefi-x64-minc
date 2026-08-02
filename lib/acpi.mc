// acpi.mc - enough ACPI to discover the CPUs.
//
// The firmware exposes the RSDP through the EFI configuration table, and from
// there RSDP -> XSDT -> MADT gives one local APIC entry per logical CPU.
//
// Table addresses are physical and directly dereferenced (no logical mapping),
// which works because UEFI identity-maps memory. The configuration table is only
// reachable while boot services are up, so call acpi_parse before the exit and
// keep a copy.
//
// Every table below is declared as a struct, so walking them is field access
// rather than offset arithmetic. The layouts are the ones ACPI specifies and
// minc's C-natural alignment reproduces them: 36 bytes for the common header,
// 44 for the MADT before its first entry, 8 for a local APIC entry.

import efi;

// One EFI_CONFIGURATION_TABLE entry, 24 bytes.
struct EfiConfigEntry {
    EfiGuid guid;
    u64 table;
}

// Root pointer. Only the XSDT address is needed here.
struct AcpiRsdp {
    u8[8] signature;
    u8 checksum;
    u8[6] oem_id;
    u8 revision;
    u32 rsdt_address;
    u32 length;
    u64 xsdt_address;
    u8 extended_checksum;
    u8[3] reserved;
}

// Common header. Every table starts with it, the XSDT and MADT included.
struct AcpiSdtHeader {
    u8[4] signature;
    u32 length;
    u8 revision;
    u8 checksum;
    u8[6] oem_id;
    u8[8] oem_table_id;
    u32 oem_revision;
    u32 creator_id;
    u32 creator_revision;
}

// Multiple APIC Description Table. A run of variable-length entries follows.
struct AcpiMadt {
    AcpiSdtHeader header;
    u32 local_apic_address;
    u32 flags;
}

// Every MADT entry starts with these two bytes.
struct AcpiEntry {
    u8 type;
    u8 length;
}

// MADT entry type 0, one per logical CPU.
struct AcpiLocalApic {
    u8 type;
    u8 length;
    u8 acpi_id;
    u8 apic_id;
    u32 flags;
}

// One local APIC, which is one logical CPU.
struct AcpiCpu {
    u8 acpi_id;
    u8 apic_id;
    bool enabled;
}

AcpiCpu[64] acpi_cpus;
i32 acpi_cpu_n = 0;
u64 acpi_lapic_base = 0;     // LAPIC MMIO base, from the MADT

// Find the ACPI 2.0 RSDP in the configuration table, or return 0.
u64 acpi_find_rsdp(EfiSystemTable* st) {
    EfiConfigEntry* e = cast(EfiConfigEntry*, st.configuration_table);
    for u64 i = 0; i < st.number_of_table_entries; i = i + 1 {
        // 8868E871-E4F1-11D3-BC22-0080C73C8881
        if e[i].guid.data1 != 0x8868E871 { continue; }
        if e[i].guid.data2 != 0xE4F1 { continue; }
        if e[i].guid.data3 != 0x11D3 { continue; }
        u8[8] d = e[i].guid.data4;
        if d[0] == 0xBC && d[1] == 0x22 && d[2] == 0x00 && d[3] == 0x80 &&
           d[4] == 0xC7 && d[5] == 0x3C && d[6] == 0x88 && d[7] == 0x81 {
            return e[i].table;
        }
    }
    return 0;
}

// Walk the XSDT pointer array for the MADT, or return 0.
u64 acpi_find_madt(u64 rsdp) {
    if rsdp == 0 { return 0; }
    AcpiRsdp* r = cast(AcpiRsdp*, rsdp);
    u64 xsdt = r.xsdt_address;
    if xsdt == 0 { return 0; }

    AcpiSdtHeader* x = cast(AcpiSdtHeader*, xsdt);
    u64 entries = (x.length - sizeof(AcpiSdtHeader)) / 8;
    u64* tables = cast(u64*, xsdt + sizeof(AcpiSdtHeader));
    for u64 i = 0; i < entries; i = i + 1 {
        AcpiSdtHeader* h = cast(AcpiSdtHeader*, tables[i]);
        u8[4] s = h.signature;
        if s[0] == 'A' && s[1] == 'P' && s[2] == 'I' && s[3] == 'C' {
            return tables[i];
        }
    }
    return 0;
}

// Fill acpi_cpus, acpi_cpu_n and acpi_lapic_base. Returns the number of
// enabled CPUs, or 0 when there is no MADT.
i32 acpi_parse(EfiSystemTable* st) {
    acpi_cpu_n = 0;
    u64 madt = acpi_find_madt(acpi_find_rsdp(st));
    if madt == 0 { return 0; }

    AcpiMadt* m = cast(AcpiMadt*, madt);
    acpi_lapic_base = m.local_apic_address;

    u64 pos = madt + sizeof(AcpiMadt);
    u64 end = madt + m.header.length;
    i32 enabled = 0;
    while pos < end {
        AcpiEntry* head = cast(AcpiEntry*, pos);
        if head.length == 0 { break; }                   // malformed, stop
        if head.type == 0 && acpi_cpu_n < 64 {           // Processor Local APIC
            AcpiLocalApic* a = cast(AcpiLocalApic*, pos);
            i32 k = acpi_cpu_n;
            acpi_cpus[k].acpi_id = a.acpi_id;
            acpi_cpus[k].apic_id = a.apic_id;
            acpi_cpus[k].enabled = (a.flags & 1) != 0;
            acpi_cpu_n = acpi_cpu_n + 1;
            if (a.flags & 1) != 0 { enabled = enabled + 1; }
        }
        pos = pos + head.length;
    }
    return enabled;
}

// 10_cpus.mc - ask the firmware how many CPUs there are.
//
//   ./run.ps1 kernel/10_cpus.mc                       (boots with 4 CPUs)
//   ./run.ps1 kernel/10_cpus.mc -Headless -Expect "cpus: 4"
//   ./run.ps1 kernel/10_cpus.mc -Smp 8                (any count works)
//
// The other cpu cores need to be activated, starting with enumeration. Its 
// APIC id has to be read from a table. The ACPI is where the firmware puts 
// it: the EFI configuration table holds the RSDP, the RSDP points at the XSDT, 
// and the XSDT lists the MADT, which has one entry per logical CPU.
//
// The configuration table goes away after boot service exit, so data needs to
// be copied. The example copies the data from firmware and prints after boot
// service exit. The additional cores are not yet activated.

import efi;
import console;
import acpi;

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "cpus: reading the ACPI tables\n\n");

    i32 enabled = acpi_parse(st);

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    if acpi_cpu_n == 0 {
        con_cputs(CON_RED, "no MADT, so no CPU list\n");
        while true { __hlt(); }
    }

    con_field_dec("cpus: ", acpi_cpu_n);
    con_field_dec("  enabled: ", enabled);
    con_field_hex("\nlapic base: ", acpi_lapic_base);
    con_puts("\n\n");

    for i32 i = 0; i < acpi_cpu_n; i++ {
        con_field_dec("  cpu ", acpi_cpus[i].acpi_id);
        con_field_dec("  apic id ", acpi_cpus[i].apic_id);
        if acpi_cpus[i].enabled { con_cputs(CON_GRAY, "  enabled\n"); }
        else { con_cputs(CON_DIM, "  disabled\n"); }
    }

    if enabled > 0 && acpi_lapic_base != 0 {
        con_cputs(CON_GREEN, "\nacpi ok\n");
    } else {
        con_cputs(CON_RED, "\nacpi incomplete\n");
    }
    while true { __hlt(); }
}

// 11_smp_boot.mc - start the other cores.
//
//   ./run.ps1 kernel/11_smp_boot.mc                   (boots with 4 CPUs)
//   ./run.ps1 kernel/11_smp_boot.mc -Headless -Expect "cores online: 4/4"
//
// Example 10 found the cpu core info. This shows how to activate them.
//
// A core starts in 16-bit real mode, and it cannot be handed an address. 
// Instead it gets a page number, and a trampoline on that page jumps
// through protected mode into long mode before finally jumping into minc
// code. See lib/smp.mc for details.
//
// Three things have to be mapped before any of it works: the LAPIC, because
// the IPIs go through it, and the low 2 MiB where the trampoline runs. Both
// are MMIO or below the RAM the firmware reports.
//

import efi;
import console;
import pmm;
import paging;
import acpi;
import lapic;
import smp;

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "smp: starting the other cores\n\n");

    // ACPI first, while the configuration table is still reachable.
    i32 enabled = acpi_parse(st);

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    pmm_init(&mm);
    paging_init(&mm, con_fb, cast(u64, con_h * con_pitch * 4));

    // The started core loads this CR3 while still in 32-bit mode, so these two
    // mappings have to exist in it before the first SIPI.
    paging_map_2mb(paging_pml4, acpi_lapic_base, acpi_lapic_base);
    paging_map_2mb(paging_pml4, 0, 0);
    __write_cr3(paging_pml4);

    lapic_set_base(acpi_lapic_base);
    lapic_enable();

    con_field_dec("cores in the MADT: ", enabled);
    con_field_dec("\nthis core's apic id: ", lapic_id());
    con_puts("\n\n");

    // boot up other cores
    i32 online = smp_start_aps(paging_pml4, cast(u64, &smp_ap_entry));

    con_field_dec("cores online: ", online);
    con_field_dec("/", enabled);
    con_puts("\n");

    // Each core read its own id from its own LAPIC, so distinct ids here mean
    // distinct cores rather than one core counting up.
    for i32 i = 0; i < online - 1; i++ {
        con_field_dec("  started core, apic id ", smp_apic_ids[i]);
        con_puts("\n");
    }
    con_puts("\n");

    if online == enabled {
        con_cputs(CON_GREEN, "every core reached long mode\n");
    } else {
        con_cputs(CON_RED, "some cores never checked in\n");
    }
    while true { __hlt(); }
}

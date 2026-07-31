// 04_paging.mc - stop using the firmware's page tables and build our own.
//
//   ./run.ps1 kernel/04_paging.mc
//   ./run.ps1 kernel/04_paging.mc -Headless -Expect "on our own tables"
//
// ExitBootServices leaves the firmware's identity map in place, and examples 01
// to 03 use it. That map can't be extended, and it recides in memory the kernel
// wants to reclaim. We take the memory map, put every free frame on a list, 
// build fresh 4-level tables out of those frames, and load CR3.
//
// Long mode and PAE are already on, so the switch is a single write. The
// instruction after it runs from the same address, because the new tables map
// physical to virtual one to one.

import efi;
import console;
import pmm;
import paging;

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "paging: building our own tables\n\n");

    // The map must be taken before the exit. Its buffer is EfiLoaderData, so
    // the allocator below will not hand it out and paging keeps it mapped.
    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    pmm_init(&mm);
    con_field_dec("free frames: ", cast(i64, pmm_free_count));
    con_field_dec(" = ", cast(i64, pmm_free_mb()));
    con_cputs(CON_GRAY, " MiB\n");

    con_field_hex("firmware cr3: ", __read_cr3());
    con_puts("\n");

    // The framebuffer is MMIO above RAM, so the memory-map walk does not cover
    // it. Without this the next con_puts would fault, and the fault handler's
    // own console write would fault again.
    u64 fb_bytes = cast(u64, con_h * con_pitch * 4);
    u64 before = pmm_free_count;
    paging_init(&mm, con_fb, fb_bytes);

    con_field_hex("our cr3:      ", __read_cr3());
    con_puts("\n");
    con_field_dec("tables cost:  ", cast(i64, before - pmm_free_count));
    con_cputs(CON_GRAY, " frames\n\n");

    // Still drawing, so the framebuffer survived the switch.
    con_cputs(CON_GREEN, "paging: on our own tables\n");

    // Only reported RAM is mapped. A read past the top of it raises #PF, which
    // example 05 catches and repairs.
    con_cputs(CON_DIM, "unmapped memory now faults - see 05_demand_paging\n");

    while true { __hlt(); }
}

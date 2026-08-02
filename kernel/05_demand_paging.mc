// 05_demand_paging.mc - a page fault the kernel repairs instead of dying on.
//
//   ./run.ps1 kernel/05_demand_paging.mc
//   ./run.ps1 kernel/05_demand_paging.mc -Headless -Expect "resumed after #PF"
//
// Example 02 catches a fault, dumps the registers and halts. It can't do anything
// else, because it does not own the page tables. Since example 04 added page tables
// we can now handle this by allocating a frame, map it at the faulting address,
// and return. The CPU retries the instruction and the read succeeds.
//
// This is how demand paging, growable heaps and lazy stacks all work.

import efi;
import console;
import pmm;
import paging;
import gdt;
import idt;
import trap;

i32 pf_count = 0;

// Error-code bit 0 is P: clear means the page was not present, which is the
// case this handler repairs. A set bit 1 would mean the access was a write.
@interrupt_err void pf_handler(TrapFrame* tf) {
    pf_count = pf_count + 1;
    u64 cr2 = __read_cr2();

    con_cputs(CON_RED, "  #PF ");
    con_field_hex("cr2=", cr2);
    con_field_dec(" err=", cast(i64, tf.error_code));

    u64 frame = pmm_alloc_frame();
    paging_zero_frame(frame);
    paging_map_4kb(paging_pml4, (cr2 >> 12) << 12, frame);
    con_cputs(CON_GRAY, " -> mapped\n");
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    con_init(st);
    con_cputs(CON_CYAN, "demand paging: faults that get fixed\n\n");

    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    pmm_init(&mm);
    paging_init(&mm, con_fb, cast(u64, con_h * con_pitch * 4));

    gdt_init();
    idt_set_gate(14, cast(u64, &pf_handler));      // #PF
    idt_load();

    // Above everything paging_init mapped, so these fault whatever the machine's
    // RAM size and framebuffer address turn out to be.
    u64 demand_va = paging_top + 0x56008;
    u64 alias_a = paging_top + PAGE_2MB;
    u64 alias_b = alias_a + 0x1000;

    con_field_hex("reading ", demand_va);
    con_puts("\n");
    u64 v = *cast(u64*, demand_va);                // faults, is repaired, retries
    con_field_hex("read returned ", v);
    con_field_dec(", faults so far: ", pf_count);
    con_puts("\n\n");

    // The page is mapped now, so the same read is an ordinary load.
    v = *cast(u64*, demand_va);
    con_field_dec("read it again, faults: ", pf_count);
    con_puts("\n");
    if pf_count == 1 { con_cputs(CON_GREEN, "\nresumed after #PF\n\n"); }
    else { con_cputs(CON_RED, "\nthe read did not fault\n\n"); }

    // One frame at two addresses. Both entries point at the same physical page,
    // so a write through one is visible through the other.
    u64 shared = pmm_alloc_frame();
    paging_zero_frame(shared);
    paging_map_4kb(paging_pml4, alias_a, shared);
    paging_map_4kb(paging_pml4, alias_b, shared);
    *cast(u64*, alias_a) = 0xC0FFEE;
    con_field_hex("wrote via A: ", *cast(u64*, alias_a));
    con_field_hex("\nread via B:  ", *cast(u64*, alias_b));
    con_puts("\n");

    while true { __hlt(); }
}

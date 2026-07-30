// 01_exit_boot_services.mc — cross the line: leave the firmware behind.
//
//   ./run.ps1 kernel/01_exit_boot_services.mc
//   (the QEMU window is the serial console — type there after the handoff)
//
// ExitBootServices ends the firmware's half of the machine. No console, no
// allocator, no protocols. What survives is what was captured beforehand. 
// In this example; the memory map, and raw hardware reached through port I/O (a 16550
// serial port at 0x3F8).

import efi;
import x86;

void put_dec(i64 v) {
    if v == 0 { serial_putc(48); return; }
    noinit u8[24] t;
    i32 n = 0;
    while v > 0 {
        t[n] = cast(u8, 48 + cast(i32, v % 10));
        n++;
        v = v / 10;
    }
    for i32 i = n - 1; i >= 0; i-- { serial_putc(t[i]); }
}

void put_hex(u64 v) {
    serial_puts("0x");
    for i32 i = 15; i >= 0; i-- {
        u8 nib = cast(u8, (v >> cast(u64, i * 4)) & 0xF);
        if nib < 10 { serial_putc(cast(u8, 48 + nib)); }
        else { serial_putc(cast(u8, 87 + nib)); }
    }
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    serial_init();
    efi_puts(st, "console: this line comes from the firmware\n");
    serial_puts("serial:  this line comes from port I/O\n");

    // The map must be taken before the exit; its buffer stays valid after.
    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    serial_puts("\nboot services are gone.\n\n");

    // The snapshot still works: total up the RAM the firmware handed over.
    u64 conventional = 0;
    i64 count = cast(i64, mm.size / mm.descriptor_size);
    u8* p = cast(u8*, mm.buffer);
    for i64 i = 0; i < count; i++ {
        EfiMemoryDescriptor* d = cast(EfiMemoryDescriptor*, p + i * cast(i64, mm.descriptor_size));
        if d.type == EFI_CONVENTIONAL_MEMORY { conventional = conventional + d.number_of_pages; }
    }
    serial_puts("free RAM in the final map: ");
    put_dec(cast(i64, conventional / 256));
    serial_puts(" MiB in ");
    put_dec(count);
    serial_puts(" regions\n");

    // The machine, straight from the intrinsics.
    serial_puts("cr0 = "); put_hex(__read_cr0());
    serial_puts("  cr3 = "); put_hex(__read_cr3());
    serial_puts("\napic base msr = "); put_hex(__rdmsr(0x1B));
    serial_puts("\n\ntype something - the kernel echoes it back:\n> ");

    while true {
        while !serial_has_data() { __pause(); }
        u8 c = serial_getc();
        if c == 13 { serial_puts("\n> "); }
        else { serial_putc(c); }
    }
}

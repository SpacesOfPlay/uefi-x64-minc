// 01_exit_boot_services.mc - leave the firmware behind.
//
//   ./run.ps1 kernel/01_exit_boot_services.mc
//   (type in the QEMU window after the handoff, either tab works)
//
// ExitBootServices removes the firmware's services. No console, no allocator,
// no protocols. Only what was captured beforehand survives. Here that is the
// memory map and the framebuffer address, both read before the call. Drawing
// afterwards is stores into video memory. Port I/O, such as the 16550 serial
// port at 0x3F8, never used the firmware.

import efi;
import console;

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    serial_init();
    // The firmware console draws on the same screen with its own font and
    // cursor. con_init clears it and takes over.
    efi_puts(st, "console: this line comes from the firmware\n");
    con_init(st);
    con_cputs(CON_CYAN, "the screen and COM1 are ours now\n\n");

    // Take the map before the exit. Its buffer stays valid after.
    EfiMemoryMap mm;
    if efi_exit_boot_services(st, image_handle, &mm) == 0 {
        efi_puts(st, "ExitBootServices failed\n");
        return 1;
    }
    __cli();

    con_puts("boot services are gone.\n\n");

    // Total the RAM the firmware reported.
    u64 conventional = 0;
    i64 count = cast(i64, mm.size / mm.descriptor_size);
    u8* p = cast(u8*, mm.buffer);
    for i64 i = 0; i < count; i++ {
        EfiMemoryDescriptor* d = cast(EfiMemoryDescriptor*, p + i * cast(i64, mm.descriptor_size));
        if d.type == EFI_CONVENTIONAL_MEMORY { conventional = conventional + d.number_of_pages; }
    }
    con_field_dec("free RAM in the final map: ", cast(i64, conventional / 256));
    con_field_dec(" MiB in ", count);
    con_cputs(CON_GRAY, " regions\n");

    // CPU state, read through the intrinsics.
    con_field_hex("cr0 = ", __read_cr0());
    con_field_hex("\ncr3 = ", __read_cr3());
    con_field_hex("\napic base msr = ", __rdmsr(0x1B));
    con_puts("\n\ntype something - the kernel echoes it back:\n> ");

    // con_getc reads the PS/2 keyboard or the serial line, whichever has a
    // byte ready. Enter arrives as CR from serial and LF from the keyboard.
    while true {
        u8 c = con_getc();
        if c == '\r' || c == '\n' { con_puts("\n> "); }
        else { con_putc(c); }
    }
}

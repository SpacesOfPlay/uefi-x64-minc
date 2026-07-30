// 03_memory_map.mc — what the firmware knows about RAM.
//
//   ./run.ps1 uefi/03_memory_map.mc
//
// GetMemoryMap returns an array of typed regions. A kernel needs this map to
// know which pages it may claim after ExitBootServices; here we just total
// the regions per type. The array is strided by descriptor_size, which may
// exceed sizeof(EfiMemoryDescriptor), never index it as a plain array.

import efi;

void put_dec(EfiSystemTable* st, u64 v) {
    noinit u8[24] buf;
    i32 i = 23;
    buf[23] = 0;
    if v == 0 { i = 22; buf[22] = 48; }
    while v != 0 {
        i--;
        buf[i] = cast(u8, 48 + cast(i32, v % 10));
        v = v / 10;
    }
    efi_puts(st, &buf[i]);
}

u8* memtype_name(u32 t) {
    if t == 0 { return "reserved             "; }
    if t == 1 { return "loader code          "; }
    if t == 2 { return "loader data          "; }
    if t == 3 { return "boot services code   "; }
    if t == 4 { return "boot services data   "; }
    if t == 5 { return "runtime services code"; }
    if t == 6 { return "runtime services data"; }
    if t == 7 { return "conventional RAM     "; }
    if t == 9 { return "ACPI reclaim         "; }
    if t == 10 { return "ACPI NVS             "; }
    if t == 11 { return "MMIO                 "; }
    return "other                ";
}

// 4 KiB pages, printed in the unit that fits.
void put_pages(EfiSystemTable* st, u64 pages) {
    if pages >= 256 {
        put_dec(st, pages / 256);
        efi_puts(st, " MiB");
    } else {
        put_dec(st, pages * 4);
        efi_puts(st, " KiB");
    }
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    EfiMemoryMap mm;
    if efi_get_memory_map(st, &mm) == 0 {
        efi_puts(st, "GetMemoryMap failed\n");
        efi_wait_key(st);
        return 1;
    }

    i64 count = cast(i64, mm.size / mm.descriptor_size);
    u8* p = cast(u8*, mm.buffer);

    // Total pages per type, plus the largest free region — where a kernel
    // would put its physical allocator.
    u64[16] pages;
    u64 largest = 0;
    u64 largest_at = 0;
    for i64 i = 0; i < count; i++ {
        EfiMemoryDescriptor* d = cast(EfiMemoryDescriptor*, p + i * cast(i64, mm.descriptor_size));
        u32 t = d.type;
        if t > 15 { t = 15; }
        pages[t] = pages[t] + d.number_of_pages;
        if t == EFI_CONVENTIONAL_MEMORY && d.number_of_pages > largest {
            largest = d.number_of_pages;
            largest_at = d.physical_start;
        }
    }

    efi_puts(st, "memory map: ");
    put_dec(st, cast(u64, count));
    efi_puts(st, " regions\n\n");

    u64 total = 0;
    for u32 t = 0; t < 16; t++ {
        total = total + pages[t];
        if pages[t] == 0 { continue; }
        efi_puts(st, "  ");
        efi_puts(st, memtype_name(t));
        efi_puts(st, "  ");
        put_pages(st, pages[t]);
        efi_puts(st, "\n");
    }

    efi_puts(st, "\ntotal mapped: ");
    put_dec(st, total / 256);
    efi_puts(st, " MiB\nlargest free region: ");
    put_dec(st, largest / 256);
    efi_puts(st, " MiB at 0x");
    efi_put_hex(st, largest_at);
    efi_puts(st, "\n\npress any key to exit\n");

    efi_free(st, mm.buffer);
    efi_wait_key(st);
    return 0;
}

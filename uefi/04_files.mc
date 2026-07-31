// 04_files.mc - read a file from the EFI System Partition.
//
//   ./run.ps1 uefi/04_files.mc
//
// The firmware exposes the boot volume through the Simple File System
// protocol. This program opens \EFI\BOOT\BOOTX64.EFI, which is the file the
// firmware just booted, and checks its own PE signature.

import efi;

void put_dec(EfiSystemTable* st, u64 v) {
    noinit u8[24] buf;
    i32 i = 23;
    buf[23] = 0;
    if v == 0 { i = 22; buf[22] = '0'; }
    while v != 0 {
        i--;
        buf[i] = cast(u8, '0' + cast(i32, v % 10));
        v = v / 10;
    }
    efi_puts(st, &buf[i]);
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    EfiFileProtocol* root = efi_open_esp_root(st, image_handle);
    if root == null {
        efi_puts(st, "no filesystem on the boot volume\n");
        efi_wait_key(st);
        return 1;
    }

    u8* path = "\\EFI\\BOOT\\BOOTX64.EFI";
    EfiFileProtocol* f = efi_open_file(root, path);
    if f == null {
        efi_puts(st, "cannot open \\EFI\\BOOT\\BOOTX64.EFI\n");
        efi_wait_key(st);
        return 1;
    }

    u64 size = 0;
    u8* data = cast(u8*, efi_read_file(st, f, &size));
    f.close(f);
    if data == null {
        efi_puts(st, "read failed\n");
        efi_wait_key(st);
        return 1;
    }

    efi_puts(st, "read \\EFI\\BOOT\\BOOTX64.EFI: ");
    put_dec(st, size);
    efi_puts(st, " bytes\n");

    // 'M' 'Z' is the DOS header minc's PE writer emits, as any PE does.
    if size >= 2 && *(data + 0) == 'M' && *(data + 1) == 'Z' {
        efi_puts(st, "signature: MZ - this file is the program reading it\n");
    } else {
        efi_puts(st, "unexpected signature\n");
    }

    efi_free(st, data);
    efi_puts(st, "\npress any key to exit\n");
    efi_wait_key(st);
    return 0;
}

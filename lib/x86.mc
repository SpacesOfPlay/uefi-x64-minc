// x86.mc — bare-metal helpers built on the x86 intrinsics (__outb/__inb/...).
//
// For code running after ExitBootServices, where the firmware is gone and the
// only way to talk to hardware is port I/O. Provides a 16550 serial console
// (COM1) and a polled PS/2 keyboard.

// =====================================================================
// Serial (COM1, 0x3F8) — a debug console that survives ExitBootServices.
// =====================================================================

i32 COM1 = 0x3F8;

void serial_init() {
    __outb(COM1 + 1, 0x00);   // disable interrupts
    __outb(COM1 + 3, 0x80);   // DLAB on
    __outb(COM1 + 0, 0x03);   // divisor low  = 3 -> 38400 baud
    __outb(COM1 + 1, 0x00);   // divisor high
    __outb(COM1 + 3, 0x03);   // 8 bits, no parity, 1 stop; DLAB off
    __outb(COM1 + 2, 0xC7);   // enable + clear FIFO, 14-byte threshold
    __outb(COM1 + 4, 0x0B);   // RTS/DSR set
}

void serial_putc(u8 c) {
    while (__inb(COM1 + 5) & 0x20) == 0 { }   // wait for THR empty
    __outb(COM1, c);
}

void serial_puts(u8* s) {
    i32 i = 0;
    while *(s + i) != 0 {
        if *(s + i) == 10 { serial_putc(13); }   // \n -> \r\n
        serial_putc(*(s + i));
        i = i + 1;
    }
}

// True when a byte is waiting in the receive buffer (LSR bit 0).
bool serial_has_data() { return (__inb(COM1 + 5) & 0x01) != 0; }

// Block until a byte arrives, then return it. Pairs with serial_putc for an
// interactive console over COM1 (QEMU's serial console / a real serial cable).
u8 serial_getc() {
    while (__inb(COM1 + 5) & 0x01) == 0 { }
    return cast(u8, __inb(COM1));
}

// =====================================================================
// PS/2 keyboard (polled). Scancode set 1, US layout, unshifted.
// =====================================================================

i32 KBD_DATA = 0x60;
i32 KBD_STATUS = 0x64;

// Make-code -> ASCII (0 = no character / modifier / unmapped). Break codes
// (bit 7 set) are key releases and map through the same table after masking.
u8[128] kbd_ascii = {
    0,  27, 49, 50, 51, 52, 53, 54, 55, 56, 57, 48, 45, 61,  8,  9,  // 0x00
  113,119,101,114,116,121,117,105,111,112, 91, 93, 10,  0, 97,115,  // 0x10
  100,102,103,104,106,107,108, 59, 39, 96,  0, 92,122,120, 99,118,  // 0x20
   98,110,109, 44, 46, 47,  0, 42,  0, 32,  0,  0,  0,  0,  0,  0,  // 0x30
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x40
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x50
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x60
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0   // 0x70
};

bool kbd_has_byte() {
    return (__inb(KBD_STATUS) & 1) != 0;
}

u8 kbd_read_scancode() {
    return __inb(KBD_DATA);
}

// Block until a key-press produces a printable/known character; return it.
u8 kbd_poll_char() {
    while true {
        if kbd_has_byte() {
            u8 sc = kbd_read_scancode();
            if (sc & 0x80) == 0 {           // make code (press), not release
                u8 a = kbd_ascii[sc];
                if a != 0 { return a; }
            }
        }
    }
}

// Shifted variants (Shift held). Same scancode layout as kbd_ascii.
u8[128] kbd_ascii_shift = {
    0,  27, 33, 64, 35, 36, 37, 94, 38, 42, 40, 41, 95, 43,  8,  9,  // 0x00
   81, 87, 69, 82, 84, 89, 85, 73, 79, 80,123,125, 10,  0, 65, 83,  // 0x10
   68, 70, 71, 72, 74, 75, 76, 58, 34,126,  0,124, 90, 88, 67, 86,  // 0x20
   66, 78, 77, 60, 62, 63,  0, 42,  0, 32,  0,  0,  0,  0,  0,  0,  // 0x30
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x40
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x50
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  // 0x60
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0   // 0x70
};
bool kbd_shift = false;

// Non-blocking: the next pressed character, or 0 if none is ready. Tracks the
// Shift modifier; key releases and other modifiers yield 0.
u8 kbd_try_char() {
    if !kbd_has_byte() { return 0; }
    u8 sc = kbd_read_scancode();
    u8 code = sc & 0x7F;
    bool release = (sc & 0x80) != 0;
    if code == 0x2A || code == 0x36 { kbd_shift = !release; return 0; }   // L/R Shift
    if release { return 0; }
    if kbd_shift { return kbd_ascii_shift[code]; }
    return kbd_ascii[code];
}

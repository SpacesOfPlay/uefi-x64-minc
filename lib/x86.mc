// x86.mc - bare-metal helpers built on the x86 intrinsics (__outb/__inb/...).
//
// For code running after ExitBootServices, where port I/O is the only way to
// reach hardware. Provides a 16550 serial port (COM1) and a polled PS/2
// keyboard.

// =====================================================================
// Serial (COM1, 0x3F8). Works after ExitBootServices.
// =====================================================================

const i32 COM1 = 0x3F8;

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
        if *(s + i) == '\n' { serial_putc('\r'); }   // \n -> \r\n
        serial_putc(*(s + i));
        i = i + 1;
    }
}

// True when a byte is waiting in the receive buffer (LSR bit 0).
bool serial_has_data() { return (__inb(COM1 + 5) & 0x01) != 0; }

// Block until a byte arrives, then return it.
u8 serial_getc() {
    while (__inb(COM1 + 5) & 0x01) == 0 { }
    return cast(u8, __inb(COM1));
}

// =====================================================================
// PIT (8253/8254, 1.193182 MHz). Channel 2 is gated by port 0x61.
// Times a delay without an interrupt.
// =====================================================================

// Busy-wait `us` microseconds. The count is us * 1193182 / 1000000, and a
// 16-bit counter caps one shot near 54 ms, so longer waits are split.
void pit_delay_us(u32 us) {
    u64 left = cast(u64, us) * 1193182 / 1000000;
    if left == 0 { left = 1; }
    while left > 0 {
        u64 c = left;
        if c > 65535 { c = 65535; }
        left = left - c;

        u8 p = __inb(0x61);
        __outb(0x61, cast(u8, (cast(i32, p) & 0xFC) | 1));   // ch2 gate on, speaker off
        __outb(0x43, 0xB0);                                  // ch2, lo/hi byte, mode 0
        __outb(0x42, cast(u8, c & 0xFF));
        __outb(0x42, cast(u8, (c >> 8) & 0xFF));
        while (__inb(0x61) & 0x20) == 0 { }                  // wait for ch2 OUT high
    }
}

// =====================================================================
// PS/2 keyboard (polled). Scancode set 1, US layout, unshifted.
// =====================================================================

const i32 KBD_DATA = 0x60;
const i32 KBD_STATUS = 0x64;

// Make-code -> ASCII. 0 means no character: a modifier, or unmapped. Break
// codes (bit 7 set) are key releases and index the same table after masking.
const u8[128] kbd_ascii = {
    // 0x00
         0, '\x1B',    '1',    '2',    '3',    '4',    '5',    '6',
       '7',    '8',    '9',    '0',    '-',    '=', '\x08',   '\t',
    // 0x10
       'q',    'w',    'e',    'r',    't',    'y',    'u',    'i',
       'o',    'p',    '[',    ']',   '\n',      0,    'a',    's',
    // 0x20
       'd',    'f',    'g',    'h',    'j',    'k',    'l',    ';',
      '\'',    '`',      0,   '\\',    'z',    'x',    'c',    'v',
    // 0x30
       'b',    'n',    'm',    ',',    '.',    '/',      0,    '*',
         0,    ' ',      0,      0,      0,      0,      0,      0,
    // 0x40-0x7F: function keys, keypad, extended. Unmapped.
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

bool kbd_has_byte() {
    return (__inb(KBD_STATUS) & 1) != 0;
}

u8 kbd_read_scancode() {
    return __inb(KBD_DATA);
}

// Block until a key press maps to a character, then return it.
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
const u8[128] kbd_ascii_shift = {
    // 0x00
         0, '\x1B',    '!',    '@',    '#',    '$',    '%',    '^',
       '&',    '*',    '(',    ')',    '_',    '+', '\x08',   '\t',
    // 0x10
       'Q',    'W',    'E',    'R',    'T',    'Y',    'U',    'I',
       'O',    'P',    '{',    '}',   '\n',      0,    'A',    'S',
    // 0x20
       'D',    'F',    'G',    'H',    'J',    'K',    'L',    ':',
       '"',    '~',      0,    '|',    'Z',    'X',    'C',    'V',
    // 0x30
       'B',    'N',    'M',    '<',    '>',    '?',      0,    '*',
         0,    ' ',      0,      0,      0,      0,      0,      0,
    // 0x40-0x7F: function keys, keypad, extended. Unmapped.
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};
bool kbd_shift = false;

// Non-blocking. Returns the next pressed character, or 0 if none is ready.
// Tracks Shift. Key releases and other modifiers return 0.
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

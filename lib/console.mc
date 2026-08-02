// console.mc - a kernel console: the GOP framebuffer plus COM1.
//
// The framebuffer is memory-mapped hardware. The address the firmware reports
// stays valid as long as nothing changes the page tables.
//
// Glyphs come from efi_font.mc's 8x8 bitmap font, scaled by CON_SCALE.
//
// Output also goes to COM1 for headless tests.

import efi;
import efi_font;
import x86;

// Framebuffer geometry, copied out of the GOP before the handoff. con_fb == 0
// means no screen, and every drawing function returns early.
u64 con_fb = 0;            // framebuffer base address
i32 con_pitch = 0;         // row stride in pixels, may exceed con_w
i32 con_w = 0;             // visible width in pixels
i32 con_h = 0;             // visible height in pixels

// The character grid, derived from the geometry in con_init.
i32 con_cols = 0;
i32 con_rows = 0;
i32 con_cx = 0;            // cursor, in cells
i32 con_cy = 0;
i32 con_cellw = 0;         // glyph cell width in pixels
i32 con_rowh = 0;          // line height including the gap
i32 con_marginx = 0;       // left padding

const i32 CON_SCALE = 2;         // one font pixel becomes a 2x2 block -> 16px glyphs
const i32 CON_VGAP = 8;          // blank pixels between rows -> 24px lines

const u32 CON_BG = 0x00102838;   // dark slate

const u32 CON_GREEN = 0x0080FF80;
const u32 CON_CYAN = 0x0080FFFF;
const u32 CON_YELLOW = 0x00F0E060;
const u32 CON_GRAY = 0x00C8C8C8;
const u32 CON_DIM = 0x0060A0C0;
const u32 CON_RED = 0x00FF6060;

u32 con_fg = 0x0080FF80;   // current text colour, assign before printing

// Start serial and capture the framebuffer. Call while boot services are up.
void con_init(EfiSystemTable* st) {
    serial_init();
    con_cellw = 8 * CON_SCALE;
    con_rowh = 8 * CON_SCALE + CON_VGAP;
    con_marginx = con_cellw / 2;

    EfiGraphicsOutputProtocol* gop = efi_locate_gop(st);
    if gop == null { return; }
    if gop.mode == null || gop.mode.info == null { return; }
    // Only RGBX (0) and BGRX (1) are linear 32-bit surfaces. PixelBitMask (2)
    // and PixelBltOnly (3) cannot be written as u32 stores.
    if gop.mode.info.pixel_format > 1 { return; }
    if gop.mode.frame_buffer_base == 0 { return; }

    i32 w = cast(i32, gop.mode.info.horizontal_resolution);
    i32 h = cast(i32, gop.mode.info.vertical_resolution);
    // Size the grid from the visible resolution, not the pitch.
    i32 cols = (w - con_marginx) / con_cellw;
    i32 rows = h / con_rowh;
    if cols < 1 || rows < 1 { return; }

    // Copy the geometry out and drop the protocol pointer.
    con_fb = gop.mode.frame_buffer_base;
    con_pitch = efi_fb_pitch(gop);
    con_w = w;
    con_h = h;
    con_cols = cols;
    con_rows = rows;
    con_cx = 0;
    con_cy = 0;
    con_clear();
}

void con_fill(i32 x, i32 y, i32 w, i32 h, u32 color) {
    if con_fb == 0 { return; }
    u32* fb = cast(u32*, con_fb);
    for i32 ry = 0; ry < h; ry++ {
        i32 base = (y + ry) * con_pitch + x;
        for i32 rx = 0; rx < w; rx++ { fb[base + rx] = color; }
    }
}

// Clear the whole panel.
void con_clear() {
    if con_fb == 0 { return; }
    con_fill(0, 0, con_w, con_h, CON_BG);
    con_cx = 0;
    con_cy = 0;
}

// Move every text row up one line and clear the last. Reads the framebuffer
// back, which is uncached MMIO on real hardware and much slower than RAM.
// A shadow buffer would avoid the read but needs memory management.
void con_scroll() {
    u32* fb = cast(u32*, con_fb);
    i32 bot = con_rows * con_rowh;
    i32 top = bot - con_rowh;
    for i32 y = 0; y < top; y++ {
        i32 dst = y * con_pitch;
        i32 src = (y + con_rowh) * con_pitch;
        for i32 x = 0; x < con_w; x++ { fb[dst + x] = fb[src + x]; }
    }
    con_fill(0, top, con_w, con_rowh, CON_BG);
}

void con_newline() {
    con_cx = 0;
    con_cy = con_cy + 1;
    if con_cy >= con_rows { con_scroll(); con_cy = con_rows - 1; }
}

void con_putc(u8 c) {
    // Serial first. serial_putc does not expand the line ending.
    if c == '\n' { serial_putc('\r'); }
    serial_putc(c);
    if con_fb == 0 { return; }

    if c == '\n' { con_newline(); }
    else if c == '\r' { con_cx = 0; }
    else if c == '\x08' { if con_cx > 0 { con_cx = con_cx - 1; } }   // backspace
    else if c >= ' ' && c <= '~' {
        // Wrap before drawing, so a full line does not emit a blank row.
        if con_cx >= con_cols { con_newline(); }
        i32 px = con_marginx + con_cx * con_cellw;
        i32 py = con_cy * con_rowh;
        con_fill(px, py, con_cellw, con_rowh, CON_BG);   // so a space erases
        // Centre the glyph in the row, half the gap above and half below.
        efi_draw_char_fb(con_fb, con_pitch, px, py + CON_VGAP / 2, c, con_fg, CON_SCALE);
        con_cx = con_cx + 1;
    }
}

void con_puts(u8* s) {
    i32 i = 0;
    while s[i] != 0 {
        con_putc(s[i]);
        i = i + 1;
    }
}

// Print one string in a colour, then restore the previous colour.
void con_cputs(u32 color, u8* s) {
    u32 prev = con_fg;
    con_fg = color;
    con_puts(s);
    con_fg = prev;
}

void con_put_dec(i64 v) {
    if v == 0 { con_putc('0'); return; }
    if v < 0 { con_putc('-'); v = -v; }
    noinit u8[24] t;
    i32 n = 0;
    while v > 0 {
        t[n] = cast(u8, '0' + cast(i32, v % 10));
        n++;
        v = v / 10;
    }
    for i32 i = n - 1; i >= 0; i-- { con_putc(t[i]); }
}

void con_put_hex(u64 v) {
    con_puts("0x");
    for i32 i = 15; i >= 0; i-- {
        u8 nib = cast(u8, (v >> cast(u64, i * 4)) & 0xF);
        if nib < 10 { con_putc(cast(u8, '0' + nib)); }
        else { con_putc(cast(u8, 'a' + nib - 10)); }
    }
}

// A labelled value: gray label, yellow value. Most kernel output has this shape.
void con_field_dec(u8* label, i64 v) {
    u32 prev = con_fg;
    con_cputs(CON_GRAY, label);
    con_fg = CON_YELLOW;
    con_put_dec(v);
    con_fg = prev;
}

void con_field_hex(u8* label, u64 v) {
    u32 prev = con_fg;
    con_cputs(CON_GRAY, label);
    con_fg = CON_YELLOW;
    con_put_hex(v);
    con_fg = prev;
}

// Block until a character arrives on serial or the PS/2 keyboard.
u8 con_getc() {
    while true {
        if serial_has_data() { return serial_getc(); }
        if con_fb != 0 {
            u8 c = kbd_try_char();
            if c != 0 { return c; }
        }
        __pause();
    }
}

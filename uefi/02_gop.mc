// 02_gop.mc — pixels: draw into the Graphics Output Protocol framebuffer.
//
//   ./run.ps1 uefi/02_gop.mc
//
// The GOP hands over a linear framebuffer: base address, resolution, and the
// row pitch. After that, graphics is just stores. Pixels are 32-bit
// 0x00RRGGBB under the common BGRX layout.

import efi;
import efi_font;

// Append v as decimal digits at dst+pos; return the new position.
i32 fmt_dec(u8* dst, i32 pos, i64 v) {
    if v >= 10 { pos = fmt_dec(dst, pos, v / 10); }
    *(dst + pos) = cast(u8, 48 + cast(i32, v % 10));
    return pos + 1;
}

void fill_rect(u32* fb, i32 pitch, i32 x, i32 y, i32 w, i32 h, u32 color) {
    for i32 dy = 0; dy < h; dy++ {
        for i32 dx = 0; dx < w; dx++ {
            *(fb + (y + dy) * pitch + x + dx) = color;
        }
    }
}

u64 efi_main(void* image_handle, EfiSystemTable* st) {
    efi_disable_watchdog(st);

    EfiGraphicsOutputProtocol* gop = efi_locate_gop(st);
    if gop == null {
        efi_puts(st, "no graphics output protocol\n");
        efi_wait_key(st);
        return 0;
    }

    i32 w = cast(i32, gop.mode.info.horizontal_resolution);
    i32 h = cast(i32, gop.mode.info.vertical_resolution);
    i32 pitch = efi_fb_pitch(gop);
    u32* fb = cast(u32*, gop.mode.frame_buffer_base);

    // XOR texture: the whole background from one integer expression per pixel.
    for i32 y = 0; y < h; y++ {
        for i32 x = 0; x < w; x++ {
            u32 v = cast(u32, (x ^ y) & 0xFF);
            *(fb + y * pitch + x) = ((v >> 3) << 16) | ((v >> 2) << 8) | v;
        }
    }

    // A panel behind the text so it reads on the busy background.
    i32 pw = 480;
    i32 ph = 150;
    i32 px = (w - pw) / 2;
    i32 py = (h - ph) / 2;
    fill_rect(fb, pitch, px, py, pw, ph, 0x00102838);

    u8* title = "minc GOP demo";
    efi_draw_text(gop, (w - efi_text_width(title, 4)) / 2, py + 24, title, 0x00F0F0F0, 4);

    noinit u8[48] line;
    i32 n = fmt_dec(&line[0], 0, w);
    line[n] = 32; n++; line[n] = 120; n++; line[n] = 32; n++;   // " x "
    n = fmt_dec(&line[0], n, h);
    line[n] = 0;
    efi_draw_text(gop, (w - efi_text_width(&line[0], 2)) / 2, py + 70, &line[0], 0x0080A0C0, 2);

    u8* hint = "press any key to exit";
    efi_draw_text(gop, (w - efi_text_width(hint, 2)) / 2, py + 104, hint, 0x00607890, 2);

    efi_wait_key(st);
    return 0;
}

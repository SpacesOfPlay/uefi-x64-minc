// efi.mc - minimal UEFI surface for the `--target uefi-x64` backend.
//
// A UEFI application is a freestanding PE32+ image whose entry is
//   u64 efi_main(void* image_handle, EfiSystemTable* st)
// The firmware passes the image handle and system table in rcx/rdx under
// the Microsoft x64 calling convention, which the uefi target uses, so the
// entry needs no wrapper. Services are reached through the table's nested
// protocol vtables (structs of function pointers), not through imports.
//
// Layout matches the UEFI spec field-for-field. minc lays structs out with
// C-natural alignment, so the offsets match the firmware's tables.

// EFI_STATUS success code. Errors set the high bit, so callers test against
// EFI_SUCCESS rather than enumerating every error value.
u64 EFI_SUCCESS = 0;

// EFI_MEMORY_TYPE values used with AllocatePool.
u32 EFI_LOADER_DATA = 2;
u32 EFI_LOADER_CODE = 1;

// EFI_TABLE_HEADER, 24 bytes. Leads every standard table.
struct EfiTableHeader {
    u64 signature;
    u32 revision;
    u32 header_size;
    u32 crc32;
    u32 reserved;
}

// EFI_GUID, 16 bytes. Used to look up protocols via LocateProtocol.
struct EfiGuid {
    u32 data1;
    u16 data2;
    u16 data3;
    u8[8] data4;
}

// EFI_INPUT_KEY returned by ReadKeyStroke.
struct EfiInputKey {
    u16 scan_code;
    u16 unicode_char;
}

// EFI_SIMPLE_TEXT_INPUT_PROTOCOL (ConIn).
struct EfiSimpleTextInputProtocol {
    fn(void*, u64): u64 reset;
    fn(void*, EfiInputKey*): u64 read_key_stroke;
    void* wait_for_key;
}

// EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL (ConOut / StdErr). Every entry takes the
// protocol pointer as its first ("This") argument. Only output_string is used
// here. The rest keep the vtable offsets correct.
struct EfiSimpleTextOutputProtocol {
    fn(void*, u64): u64 reset;
    fn(void*, u16*): u64 output_string;
    fn(void*, u16*): u64 test_string;
    fn(void*, u64, u64*, u64*): u64 query_mode;
    fn(void*, u64): u64 set_mode;
    fn(void*, u64): u64 set_attribute;
    fn(void*): u64 clear_screen;
    fn(void*, u64, u64): u64 set_cursor_position;
    fn(void*, u64): u64 enable_cursor;
    void* mode;
}

// EFI_BOOT_SERVICES. Every member is a pointer-sized slot, and the spec order
// matters because services are reached by offset. Members this library does
// not call are typed void*, present only to hold their offsets.
struct EfiBootServices {
    EfiTableHeader hdr;
    // Task priority
    void* raise_tpl;
    void* restore_tpl;
    // Memory
    void* allocate_pages;
    void* free_pages;
    fn(u64*, void*, u64*, u64*, u32*): u64 get_memory_map;
    fn(u32, u64, void**): u64 allocate_pool;
    fn(void*): u64 free_pool;
    // Event & timer
    void* create_event;
    void* set_timer;
    fn(u64, void**, u64*): u64 wait_for_event;
    void* signal_event;
    void* close_event;
    void* check_event;
    // Protocol handler
    void* install_protocol_interface;
    void* reinstall_protocol_interface;
    void* uninstall_protocol_interface;
    fn(void*, void*, void**): u64 handle_protocol;
    void* reserved;
    void* register_protocol_notify;
    void* locate_handle;
    void* locate_device_path;
    void* install_configuration_table;
    // Image
    void* load_image;
    void* start_image;
    void* exit;
    void* unload_image;
    fn(void*, u64): u64 exit_boot_services;
    // Misc
    void* get_next_monotonic_count;
    fn(u64): u64 stall;
    fn(u64, u64, u64, u16*): u64 set_watchdog_timer;
    // Driver support
    void* connect_controller;
    void* disconnect_controller;
    // Open/close protocol
    void* open_protocol;
    void* close_protocol;
    void* open_protocol_information;
    // Library
    void* protocols_per_handle;
    void* locate_handle_buffer;
    fn(void*, void*, void**): u64 locate_protocol;
    void* install_multiple_protocol_interfaces;
    void* uninstall_multiple_protocol_interfaces;
    // CRC32
    void* calculate_crc32;
    // Misc memory
    fn(void*, void*, u64): void copy_mem;
    fn(void*, u64, u8): void set_mem;
    void* create_event_ex;
}

// EFI_SYSTEM_TABLE.
struct EfiSystemTable {
    EfiTableHeader hdr;
    u16* firmware_vendor;
    u32 firmware_revision;
    void* console_in_handle;
    EfiSimpleTextInputProtocol* con_in;
    void* console_out_handle;
    EfiSimpleTextOutputProtocol* con_out;
    void* standard_error_handle;
    EfiSimpleTextOutputProtocol* std_err;
    void* runtime_services;
    EfiBootServices* boot_services;
    u64 number_of_table_entries;
    void* configuration_table;
}

// EFI_MEMORY_DESCRIPTOR. GetMemoryMap reports descriptor_size separately, and
// it may exceed this struct. Stride the array by descriptor_size, never by
// sizeof(EfiMemoryDescriptor).
struct EfiMemoryDescriptor {
    u32 type;
    u32 pad;
    u64 physical_start;
    u64 virtual_start;
    u64 number_of_pages;
    u64 attribute;
}

// Result of efi_get_memory_map: the buffer, plus the key and stride needed to
// walk it and to call ExitBootServices.
struct EfiMemoryMap {
    void* buffer;
    u64 size;                 // bytes filled
    u64 map_key;
    u64 descriptor_size;
    u32 descriptor_version;
}

// Common EFI_MEMORY_TYPE values a kernel cares about after exit.
u32 EFI_CONVENTIONAL_MEMORY = 7;

// --- EFI_GRAPHICS_OUTPUT_PROTOCOL (GOP) ---

struct EfiGraphicsOutputModeInformation {
    u32 version;
    u32 horizontal_resolution;
    u32 vertical_resolution;
    u32 pixel_format;
    u32 red_mask;
    u32 green_mask;
    u32 blue_mask;
    u32 reserved_mask;
    u32 pixels_per_scan_line;
}

struct EfiGraphicsOutputProtocolMode {
    u32 max_mode;
    u32 mode;
    EfiGraphicsOutputModeInformation* info;
    u64 size_of_info;
    u64 frame_buffer_base;
    u64 frame_buffer_size;
}

struct EfiGraphicsOutputProtocol {
    void* query_mode;
    void* set_mode;
    void* blt;
    EfiGraphicsOutputProtocolMode* mode;
}

// =====================================================================
// Console output
// =====================================================================

// Write an ASCII string to the console. UEFI takes UTF-16, so the bytes are
// widened on a stack buffer and '\n' is expanded to "\r\n". Strings longer
// than the buffer are split across calls.
void efi_puts(EfiSystemTable* st, u8* s) {
    u16[256] buf;
    i32 n = 0;
    i32 i = 0;
    while *(s + i) != 0 {
        if n >= 252 {
            buf[n] = 0;
            st.con_out.output_string(st.con_out, buf);
            n = 0;
        }
        u8 c = *(s + i);
        if c == '\n' {
            buf[n] = '\r';        // carriage return before newline
            n = n + 1;
        }
        buf[n] = cast(u16, c);
        n = n + 1;
        i = i + 1;
    }
    buf[n] = 0;
    st.con_out.output_string(st.con_out, buf);
}

// Print an unsigned 64-bit value as hexadecimal, with no "0x" prefix.
void efi_put_hex(EfiSystemTable* st, u64 v) {
    u8[17] tmp;
    i32 i = 16;
    tmp[16] = 0;
    if v == 0 {
        i = 15;
        tmp[15] = '0';
    }
    while v != 0 {
        i = i - 1;
        u8 d = cast(u8, v & 0xF);
        if d < 10 { tmp[i] = cast(u8, '0' + d); }       // '0'..'9'
        else { tmp[i] = cast(u8, 'a' + d - 10); }       // 'a'..'f'
        v = v >> 4;
    }
    efi_puts(st, &tmp[i]);
}

// =====================================================================
// Console input
// =====================================================================

// Block until a key is pressed, then return its Unicode character. Polls
// ReadKeyStroke, which returns non-success while the buffer is empty, so no
// event wiring is needed.
u16 efi_wait_key(EfiSystemTable* st) {
    EfiInputKey key;
    while st.con_in.read_key_stroke(st.con_in, &key) != EFI_SUCCESS { }
    return key.unicode_char;
}

// =====================================================================
// Memory
// =====================================================================

// Allocate `size` bytes of EfiLoaderData pool memory. Returns null on failure.
void* efi_alloc(EfiSystemTable* st, u64 size) {
    void* buf = null;
    u64 status = st.boot_services.allocate_pool(EFI_LOADER_DATA, size, &buf);
    if status != EFI_SUCCESS { return null; }
    return buf;
}

void efi_free(EfiSystemTable* st, void* p) {
    st.boot_services.free_pool(p);
}

// Firmware block copy and fill. The memcpy and memset builtins are not
// available on the uefi target, so use these instead.
void efi_copy_mem(EfiSystemTable* st, void* dst, void* src, u64 len) {
    st.boot_services.copy_mem(dst, src, len);
}

void efi_set_mem(EfiSystemTable* st, void* dst, u64 len, u8 value) {
    st.boot_services.set_mem(dst, len, value);
}

// =====================================================================
// Misc boot services
// =====================================================================

// Busy-wait for `microseconds` via the firmware timer.
void efi_stall(EfiSystemTable* st, u64 microseconds) {
    st.boot_services.stall(microseconds);
}

// Disable the firmware watchdog, which otherwise resets the machine after the
// default 5-minute timeout. Timeout 0 disarms it.
void efi_disable_watchdog(EfiSystemTable* st) {
    st.boot_services.set_watchdog_timer(0, 0, 0, null);
}

// =====================================================================
// Graphics Output Protocol
// =====================================================================

// Fill `g` with the EFI_GRAPHICS_OUTPUT_PROTOCOL GUID
// {9042a9de-23dc-4a38-96fb-7aded080516a}.
void efi_gop_guid(EfiGuid* g) {
    g.data1 = 0x9042a9de;
    g.data2 = 0x23dc;
    g.data3 = 0x4a38;
    g.data4[0] = 0x96;
    g.data4[1] = 0xfb;
    g.data4[2] = 0x7a;
    g.data4[3] = 0xde;
    g.data4[4] = 0xd0;
    g.data4[5] = 0x80;
    g.data4[6] = 0x51;
    g.data4[7] = 0x6a;
}

// Locate the active Graphics Output Protocol, or null if the firmware has none.
EfiGraphicsOutputProtocol* efi_locate_gop(EfiSystemTable* st) {
    EfiGuid guid;
    efi_gop_guid(&guid);
    void* gop = null;
    u64 status = st.boot_services.locate_protocol(&guid, null, &gop);
    if status != EFI_SUCCESS { return null; }
    return cast(EfiGraphicsOutputProtocol*, gop);
}

// Fill the entire framebuffer with a 32-bit packed pixel, usually 0x00RRGGBB
// under the common BGRX format. Writes to the linear framebuffer directly.
void efi_gop_fill(EfiGraphicsOutputProtocol* gop, u32 color) {
    u32* fb = cast(u32*, gop.mode.frame_buffer_base);
    u64 n = gop.mode.frame_buffer_size / 4;
    for u64 i = 0; i < n; i = i + 1 {
        *(fb + i) = color;
    }
}

// =====================================================================
// Boot-services handoff (memory map + ExitBootServices)
// =====================================================================

// Copy the firmware memory map into a freshly allocated pool buffer. Returns
// 1 on success with `out` filled, 0 on failure. The caller owns the buffer and
// frees it with efi_free, or leaves it allocated once boot services are gone.
// The buffer is oversized, because the pool allocation itself changes the map.
i32 efi_get_memory_map(EfiSystemTable* st, EfiMemoryMap* out) {
    u64 size = 0;
    u64 key = 0;
    u64 dsize = 0;
    u32 dver = 0;
    // First call sizes the map (returns EFI_BUFFER_TOO_SMALL).
    st.boot_services.get_memory_map(&size, null, &key, &dsize, &dver);
    if dsize == 0 { return 0; }
    size = size + dsize * 8;          // slack for descriptors AllocatePool adds
    void* buf = efi_alloc(st, size);
    if buf == null { return 0; }
    u64 status = st.boot_services.get_memory_map(&size, buf, &key, &dsize, &dver);
    if status != EFI_SUCCESS {
        efi_free(st, buf);
        return 0;
    }
    out.buffer = buf;
    out.size = size;
    out.map_key = key;
    out.descriptor_size = dsize;
    out.descriptor_version = dver;
    return 1;
}

// Leave boot services. On success AllocatePool, console output, file I/O and
// timers stop working. Only runtime services and values captured beforehand,
// such as the GOP framebuffer address, remain usable. `out_map` receives the
// map that was live at exit. Returns 1 on success, 0 on failure.
//
// The map key can go stale between GetMemoryMap and ExitBootServices, so this
// retries with a fresh map, as the spec requires. Nothing is allocated between
// sampling the key and the exit call, which keeps the key valid.
i32 efi_exit_boot_services(EfiSystemTable* st, void* image_handle, EfiMemoryMap* out_map) {
    for i32 attempt = 0; attempt < 8; attempt = attempt + 1 {
        EfiMemoryMap mm;
        if efi_get_memory_map(st, &mm) == 0 { return 0; }
        u64 status = st.boot_services.exit_boot_services(image_handle, mm.map_key);
        if status == EFI_SUCCESS {
            out_map.buffer = mm.buffer;
            out_map.size = mm.size;
            out_map.map_key = mm.map_key;
            out_map.descriptor_size = mm.descriptor_size;
            out_map.descriptor_version = mm.descriptor_version;
            return 1;
        }
        efi_free(st, mm.buffer);       // stale key, free and resample
    }
    return 0;
}

// =====================================================================
// File I/O (Simple File System / File protocol)
// =====================================================================

u64 EFI_FILE_MODE_READ = 1;

// EFI_LOADED_IMAGE_PROTOCOL. Holds the device handle the image booted from.
struct EfiLoadedImageProtocol {
    u32 revision;
    void* parent_handle;
    EfiSystemTable* system_table;
    void* device_handle;
    void* file_path;
    void* reserved;
    u32 load_options_size;
    void* load_options;
    void* image_base;
    u64 image_size;
    u32 image_code_type;
    u32 image_data_type;
    void* unload;
}

struct EfiSimpleFileSystemProtocol {
    u64 revision;
    fn(void*, void**): u64 open_volume;     // (This, EFI_FILE_PROTOCOL** Root)
}

struct EfiFileProtocol {
    u64 revision;
    fn(void*, void**, u16*, u64, u64): u64 open;  // (This, **New, *Name, OpenMode, Attr)
    fn(void*): u64 close;
    fn(void*): u64 delete;
    fn(void*, u64*, void*): u64 read;             // (This, *BufferSize, *Buffer)
    fn(void*, u64*, void*): u64 write;
    fn(void*, u64*): u64 get_position;
    fn(void*, u64): u64 set_position;
    fn(void*, void*, u64*, void*): u64 get_info;  // (This, *InfoType, *BufSize, *Buf)
    fn(void*, void*, u64, void*): u64 set_info;
    fn(void*): u64 flush;
}

// Widen an ASCII string into a UTF-16 buffer (UEFI paths are CHAR16).
void efi_ascii_to_utf16(u16* dst, u8* src) {
    i32 i = 0;
    while *(src + i) != 0 {
        *(dst + i) = cast(u16, *(src + i));
        i = i + 1;
    }
    *(dst + i) = 0;
}

void efi_loaded_image_guid(EfiGuid* g) {
    g.data1 = 0x5B1B31A1; g.data2 = 0x9562; g.data3 = 0x11D2;
    g.data4[0] = 0x8E; g.data4[1] = 0x3F; g.data4[2] = 0x00; g.data4[3] = 0xA0;
    g.data4[4] = 0xC9; g.data4[5] = 0x69; g.data4[6] = 0x72; g.data4[7] = 0x3B;
}

void efi_sfs_guid(EfiGuid* g) {
    g.data1 = 0x964E5B22; g.data2 = 0x6459; g.data3 = 0x11D2;
    g.data4[0] = 0x8E; g.data4[1] = 0x39; g.data4[2] = 0x00; g.data4[3] = 0xA0;
    g.data4[4] = 0xC9; g.data4[5] = 0x69; g.data4[6] = 0x72; g.data4[7] = 0x3B;
}

void efi_file_info_guid(EfiGuid* g) {
    g.data1 = 0x09576E92; g.data2 = 0x6D3F; g.data3 = 0x11D2;
    g.data4[0] = 0x8E; g.data4[1] = 0x39; g.data4[2] = 0x00; g.data4[3] = 0xA0;
    g.data4[4] = 0xC9; g.data4[5] = 0x69; g.data4[6] = 0x72; g.data4[7] = 0x3B;
}

// The EFI_LOADED_IMAGE_PROTOCOL for our own image handle, or null.
EfiLoadedImageProtocol* efi_loaded_image(EfiSystemTable* st, void* image_handle) {
    EfiGuid g;
    efi_loaded_image_guid(&g);
    void* p = null;
    if st.boot_services.handle_protocol(image_handle, &g, &p) != EFI_SUCCESS { return null; }
    return cast(EfiLoadedImageProtocol*, p);
}

// Open the root directory of a FAT volume. Uses LocateProtocol to take the
// first Simple File System the firmware exposes, which is correct for a
// single-volume boot with one ESP. The boot image's own DeviceHandle does not
// always carry SimpleFileSystem, since some firmware puts it on a child
// handle, so this is more reliable than going through LoadedImage. Returns
// null if no filesystem is present.
EfiFileProtocol* efi_open_esp_root(EfiSystemTable* st, void* image_handle) {
    EfiGuid g;
    efi_sfs_guid(&g);
    void* sfsp = null;
    if st.boot_services.locate_protocol(&g, null, &sfsp) != EFI_SUCCESS { return null; }
    EfiSimpleFileSystemProtocol* sfs = cast(EfiSimpleFileSystemProtocol*, sfsp);
    void* root = null;
    if sfs.open_volume(sfs, &root) != EFI_SUCCESS { return null; }
    return cast(EfiFileProtocol*, root);
}

// Open a file under `dir` for reading, by ASCII path such as "\\KERNEL.EFI".
EfiFileProtocol* efi_open_file(EfiFileProtocol* dir, u8* ascii_path) {
    u16[260] wpath;
    efi_ascii_to_utf16(&wpath[0], ascii_path);
    void* f = null;
    if dir.open(dir, &f, &wpath[0], EFI_FILE_MODE_READ, 0) != EFI_SUCCESS { return null; }
    return cast(EfiFileProtocol*, f);
}

// File size in bytes via GetInfo(EFI_FILE_INFO). FileSize sits at offset 8.
u64 efi_file_size(EfiFileProtocol* f) {
    u8[512] info;
    u64 sz = 512;
    EfiGuid g;
    efi_file_info_guid(&g);
    if f.get_info(f, &g, &sz, &info[0]) != EFI_SUCCESS { return 0; }
    u64* fs = cast(u64*, &info[8]);
    return *fs;
}

// Read an entire file into a freshly allocated pool buffer. Returns null on
// failure. *out_size receives the byte count.
void* efi_read_file(EfiSystemTable* st, EfiFileProtocol* f, u64* out_size) {
    u64 size = efi_file_size(f);
    if size == 0 { return null; }
    void* buf = efi_alloc(st, size);
    if buf == null { return null; }
    u64 rd = size;
    if f.read(f, &rd, buf) != EFI_SUCCESS {
        efi_free(st, buf);
        return null;
    }
    *out_size = rd;
    return buf;
}

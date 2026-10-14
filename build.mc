// build.mc — compile a minc UEFI example and boot it under QEMU + OVMF.
//
// Usage, from this folder:
//   minc run                          list the examples
//   minc run uefi/01_hello.mc         build + boot (output in the QEMU window)
//   minc run kernel/03_lapic_timer.mc
//   minc build uefi/01_hello.mc       just produce build/01_hello.efi
//   minc build all                    compile every example, boot nothing
//   minc run kernel/02_traps.mc --headless --expect "CPU EXCEPTION"
//   minc run kernel/10_cpus.mc --smp 8
//   minc clean
//
// Headless mode boots with the serial console logged to a file, lets
// the VM run for --timeout seconds (default 20), shuts it down,
// prints the log, and with --expect checks the log contains the text.
//
// QEMU + OVMF are found via MINC_QEMU / MINC_OVMF_CODE /
// MINC_OVMF_VARS, then an MSYS2 install (pacman -S
// mingw-w64-x86_64-qemu), then qemu-system-x86_64 on PATH with the
// edk2 firmware in its own share/qemu directory.
//
// minc emits VEX/AVX encodings, so the vCPU must expose AVX
// (--cpu max by default; QEMU's plain qemu64 model does not).
//
// The minc compiler is taken from MINC, then PATH, then this folder.
// Install minc from https://minc.dev.

@minc_min_version "0.9.11"

// Older minc ignores the tag above; this forces a clear error there.
when !defined(MINC_VERSION) || MINC_VERSION < 9011 {
    minc_0_9_11_or_newer_required please_update_minc;
}

import process;
import file;
import str;

when os(windows) { str EXE_SUFFIX = ".exe"; }
when os(linux) || os(macos) { str EXE_SUFFIX = ""; }

void die(str s) {
    eprint("{}\n", s);
    exit(1);
    return;
}

// "<dir>/<name><ext>", without leaking the joined name.
string join_named(str dir, str name, str ext) {
    string base = str_concat(name, ext);
    defer free(base);
    return path_join(dir, base);
}

// MINC first (an install dir or the binary itself), then PATH, then a
// binary sitting next to this script.
string find_minc() {
    string env = env_get("MINC");
    if env.len > 0 {
        if path_is_dir(env) {
            string cand = join_named(env, "minc", EXE_SUFFIX);
            free(env);
            return cand;
        }
        return env;
    }
    free(env);

    string onpath = path_which("minc");
    if onpath.len > 0 { return onpath; }
    free(onpath);

    string local = str_concat("./minc", EXE_SUFFIX);
    if path_exists(local) { return local; }
    free(local);

    return string{};
}

// Non-negative integer from a CLI argument; -1 if it is not one.
i32 str_to_i32(str s) {
    if s.len == 0 { return -1; }
    i32 v = 0;
    for i32 i = 0; i < s.len; i++ {
        u8 c = s.data[i];
        if c < '0' || c > '9' { return -1; }
        v = v * 10 + cast(i32, c - '0');
    }
    return v;
}

// The next line of s starting at *pos; advances *pos past it.
str next_line(str s, i32* pos) {
    i32 b = *pos;
    if b >= s.len { return ""; }
    i32 e = b;
    while e < s.len && s.data[e] != '\n' { e++; }
    *pos = e + 1;
    i32 stop = e;
    if stop > b && s.data[stop - 1] == '\r' { stop--; }
    return str_slice(s, b, stop);
}

// --- QEMU + OVMF -------------------------------------------------------

struct Qemu {
    string exe;
    string code;   // OVMF firmware image
    string vars;   // OVMF NVRAM template
}

// MINC_QEMU / MINC_OVMF_CODE / MINC_OVMF_VARS first, then an MSYS2
// install, then qemu-system-x86_64 on PATH with the edk2 firmware in
// its own share/qemu directory (the layout QEMU installs everywhere).
Qemu find_qemu() {
    Qemu q;
    string env_q = env_get("MINC_QEMU");
    string env_c = env_get("MINC_OVMF_CODE");
    string env_v = env_get("MINC_OVMF_VARS");
    if env_q.len > 0 && env_c.len > 0 && env_v.len > 0 && path_exists(env_q) {
        q.exe = env_q;
        q.code = env_c;
        q.vars = env_v;
        return q;
    }
    free(env_q);
    free(env_c);
    free(env_v);

    when os(windows) {
        str[2] roots = { "C:/msys64", "C:/msys2" };
        for i32 i = 0; i < 2; i++ {
            string e = path_join(roots[i], "mingw64/bin/qemu-system-x86_64.exe");
            string c = path_join(roots[i], "mingw64/share/qemu/edk2-x86_64-code.fd");
            string v = path_join(roots[i], "mingw64/share/qemu/edk2-i386-vars.fd");
            if path_exists(e) && path_exists(c) && path_exists(v) {
                q.exe = e;
                q.code = c;
                q.vars = v;
                return q;
            }
            free(e);
            free(c);
            free(v);
        }
    }

    string onpath = path_which("qemu-system-x86_64");
    if onpath.len > 0 {
        str bindir = path_dirname(onpath);
        string share = path_join(bindir, "../share/qemu");
        defer free(share);
        string c = path_join(share, "edk2-x86_64-code.fd");
        string v = path_join(share, "edk2-i386-vars.fd");
        if path_exists(c) && path_exists(v) {
            q.exe = onpath;
            q.code = c;
            q.vars = v;
            return q;
        }
        free(c);
        free(v);
    }
    free(onpath);
    return q;
}

// show-tabs draws the console tab bar in the QEMU window, so the VGA
// and serial0 consoles are one click apart instead of Ctrl+Alt+<n>.
// Only the gtk display supports it; without gtk, QEMU's default
// display stands.
bool qemu_has_gtk(str qemu) {
    ProcCmd c = { .args = { qemu, "-display", "help" }, .capture = true };
    ProcResult r = proc_run(&c);
    defer proc_result_free(&r);
    if !r.spawned { return false; }
    str o = r.out;
    i32 pos = 0;
    while pos < o.len {
        str line = next_line(o, &pos);
        if str_equal(str_trim(line), "gtk") { return true; }
    }
    return false;
}

// OVMF mirrors its console to the serial port with the escape
// sequences included (ESC[2J, ESC[=3h, ...). Those target a terminal
// emulator inside QEMU; replayed into this shell they clear the
// screen and change its mode. Strip ESC [ <params> <final letter>.
string strip_ansi(str s) {
    str_buf b;
    str_buf_init(&b);
    defer str_buf_free(&b);
    i32 i = 0;
    while i < s.len {
        u8 c = s.data[i];
        if c == 27 && i + 1 < s.len && s.data[i + 1] == '[' {
            i32 j = i + 2;
            while j < s.len {
                u8 p = s.data[j];
                bool param = (p >= '0' && p <= '9') || p == ';' || p == '=' || p == '?';
                if !param { break; }
                j++;
            }
            if j < s.len {
                u8 fin = s.data[j];
                if (fin >= 'A' && fin <= 'Z') || (fin >= 'a' && fin <= 'z') { j++; }
            }
            i = j;
            continue;
        }
        str_buf_add_byte(&b, c);
        i++;
    }
    return string(str_buf_to_str(&b));
}

// --- Examples ----------------------------------------------------------

// Compile one example to build/<name>.efi. The cwd is the repo root,
// so `import x;` resolves lib/x.mc.
bool compile_example(str minc, str src) {
    string efi = join_named("build", path_stem(src), ".efi");
    defer free(efi);
    print(">> compiling {}\n", src);
    ProcCmd cc_cmd = { .args = { minc, src, "--target", "uefi-x64", "-o", efi } };
    ProcResult cc_r = proc_run(&cc_cmd);
    i32 cc_rc = cc_r.exit_code;
    proc_result_free(&cc_r);
    return cc_rc == 0 && path_exists(efi);
}

// Every example under uefi/ and kernel/; the count that failed.
i32 compile_all(str minc) {
    i32 failed = 0;
    str[2] dirs = { "uefi", "kernel" };
    for i32 d = 0; d < 2; d++ {
        DirList l = dir_list(dirs[d], ".mc", false);
        defer dir_list_free(&l);
        for i32 i = 0; i < l.count; i++ {
            string rel = path_join(dirs[d], l.items[i]);
            defer free(rel);
            if !compile_example(minc, rel) { failed++; }
        }
    }
    return failed;
}

// "uefi/01_hello.mc", "uefi/01_hello", or a path to any .mc file.
// Caller frees; empty when nothing matches.
string resolve_source(str arg) {
    if str_ends_with(arg, ".mc") && path_exists(arg) { return string(arg); }
    string with_ext = str_concat(arg, ".mc");
    if path_exists(with_ext) { return with_ext; }
    free(with_ext);
    return string{};
}

void list_dir(str dir, str blurb) {
    DirList l = dir_list(dir, ".mc", false);
    defer dir_list_free(&l);
    if l.count == 0 { return; }
    print("{}/  {}\n", dir, blurb);
    for i32 i = 0; i < l.count; i++ {
        string rel = path_join(dir, l.items[i]);
        defer free(rel);
        print("  minc run {}\n", rel);
    }
    print("\n");
    return;
}

// With no example, list what is available and which one to start
// with, instead of a bare error.
void usage() {
    print("\n"
          "minc on UEFI x64 - compile an example and boot it under QEMU + OVMF.\n"
          "\n"
          "  minc run uefi/01_hello.mc   <- start here: a whole UEFI app in one file\n"
          "\n");
    list_dir("uefi", "on the firmware: console, graphics, memory map, files");
    list_dir("kernel", "after ExitBootServices: the bare hardware, on a console of their own");
    print("options\n"
          "  minc build <example>          compile to build/<name>.efi, do not boot\n"
          "  minc build all                compile every example\n"
          "  --headless [--expect \"text\"]  no window: print the serial log, check it for 'text'\n"
          "  --smp 4                       CPU count (default 1, or 4 for multi-core examples)\n"
          "  --timeout 20  --cpu max  --mem 256\n"
          "\n");
    return;
}

i32 main() {
    i32 argc = get_argc();
    str verb = "run";
    str target = "";
    bool headless = false;
    str expect = "";
    i32 timeout_sec = 20;
    str cpu = "max";
    i32 smp = 0;             // 0: default (1, or 4 for the multi-core examples)
    i32 mem_mb = 256;

    for i32 i = 1; i < argc; i++ {
        str a = str_from_cstr(get_arg(i));
        if str_equal(a, "--headless") { headless = true; }
        else if str_equal(a, "--expect") && i + 1 < argc {
            i++;
            expect = str_from_cstr(get_arg(i));
        }
        else if str_equal(a, "--timeout") && i + 1 < argc {
            i++;
            i32 v = str_to_i32(str_from_cstr(get_arg(i)));
            if v < 1 { die("--timeout wants seconds"); }
            timeout_sec = v;
        }
        else if str_equal(a, "--cpu") && i + 1 < argc {
            i++;
            cpu = str_from_cstr(get_arg(i));
        }
        else if str_equal(a, "--smp") && i + 1 < argc {
            i++;
            i32 v = str_to_i32(str_from_cstr(get_arg(i)));
            if v < 1 { die("--smp wants a CPU count"); }
            smp = v;
        }
        else if str_equal(a, "--mem") && i + 1 < argc {
            i++;
            i32 v = str_to_i32(str_from_cstr(get_arg(i)));
            if v < 1 { die("--mem wants megabytes"); }
            mem_mb = v;
        }
        else if i == 1 {
            // A .mc path in the verb slot means "run this".
            if str_ends_with(a, ".mc") { target = a; } else { verb = a; }
        } else if target.len == 0 { target = a; }
    }

    if str_equal(verb, "clean") {
        ignore dir_remove("build");
        print("clean.\n");
        return 0;
    }
    if !str_equal(verb, "run") && !str_equal(verb, "build") {
        usage();
        return 1;
    }
    if target.len == 0 {
        usage();
        return 0;
    }

    string minc = find_minc();
    defer free(minc);
    if minc.len == 0 {
        print("\nminc compiler not found.\n"
              "Install it:  powershell -c \"irm minc.dev/install.ps1 | iex\"\n"
              "or set MINC (see install_minc.md).\n");
        die("See README.md (Quickstart) and LICENSE.md.");
    }

    if !path_exists("lib/efi.mc") {
        die("missing lib/efi.mc — run from the repo root");
    }

    if str_equal(verb, "build") && str_equal(target, "all") {
        ignore dir_create("build");
        i32 failed = compile_all(minc);
        if failed > 0 {
            eprint("{} example(s) failed\n", failed);
            return 1;
        }
        print(">> built every example\n");
        return 0;
    }

    string src = resolve_source(target);
    defer free(src);
    if src.len == 0 {
        eprint("example not found: {}\n", target);
        exit(1);
    }
    str name = path_stem(src);
    // kernel/ examples capture the framebuffer before ExitBootServices
    // and draw their own console on it, mirrored to COM1. Both need
    // the VGA device present.
    bool is_kernel = str_equal(path_basename(path_dirname(src)), "kernel");

    // Examples about more than one CPU boot with four by default,
    // since one core tells the reader nothing. An explicit --smp
    // still wins. Everything else stays single-core.
    if smp == 0 {
        smp = 1;
        if str_equal(name, "10_cpus") || str_equal(name, "11_smp_boot") { smp = 4; }
    }

    ignore dir_create("build");
    string efi = join_named("build", name, ".efi");
    defer free(efi);

    if !compile_example(minc, src) { die("compile failed"); }
    if str_equal(verb, "build") {
        print(">> built {}\n", efi);
        return 0;
    }

    // A virtual-FAT ESP: QEMU serves this directory as the boot disk.
    ignore dir_create("build/esp/EFI/BOOT");
    if !file_copy(efi, "build/esp/EFI/BOOT/BOOTX64.EFI") {
        die("cannot stage build/esp/EFI/BOOT/BOOTX64.EFI");
    }

    Qemu q = find_qemu();
    defer free(q.exe);
    defer free(q.code);
    defer free(q.vars);
    if q.exe.len == 0 {
        print("qemu/OVMF not found.\n"
              "Install: pacman -S mingw-w64-x86_64-qemu (MSYS2),\n");
        die("or set MINC_QEMU / MINC_OVMF_CODE / MINC_OVMF_VARS.");
    }
    str qemu = q.exe;

    // OVMF needs a writable NVRAM store.
    if !file_copy(q.vars, "build/uefi_vars.fd") {
        die("cannot copy the OVMF vars image into build/");
    }

    string smp_s = format("{}", smp);
    defer free(smp_s);
    string mem_s = format("{}M", mem_mb);
    defer free(mem_s);
    string code_drive = format("if=pflash,format=raw,readonly=on,file={}", q.code);
    defer free(code_drive);

    // The relative fat:rw: path resolves from this script's working
    // directory, the repo root, and keeps the drive-letter colon out
    // of the option syntax.
    ProcCmd vm = { .args = {
        qemu, "-machine", "q35", "-cpu", cpu,
        "-smp", smp_s, "-m", mem_s,
        "-drive", code_drive,
        "-drive", "if=pflash,format=raw,file=build/uefi_vars.fd",
        "-drive", "format=raw,file=fat:rw:build/esp",
        "-net", "none"
    } };

    if headless {
        str log = "build/serial.log";
        ignore file_remove(log);
        proc_arg(&vm, "-display");
        proc_arg(&vm, "none");
        proc_arg(&vm, "-serial");
        proc_arg(&vm, "file:build/serial.log");
        vm.capture = true;                    // QEMU chatter stays out of the log
        vm.timeout_ms = timeout_sec * 1000;
        print(">> qemu headless ({}s)\n", timeout_sec);
        ProcResult r = proc_run(&vm);
        bool started = r.spawned;
        proc_result_free(&r);
        if !started { die("could not start QEMU"); }

        // The log keeps the raw bytes. What is matched and printed is
        // escape-free, so a stray sequence cannot split a match or
        // reach this terminal.
        string raw = file_read_str(log);
        defer free(raw);
        string ser = strip_ansi(raw);
        defer free(ser);
        print("--- serial console ---\n{}\n", ser);
        if expect.len > 0 {
            if str_find(ser, expect) >= 0 {
                print("MATCH: '{}'\n", expect);
                return 0;
            }
            print("MISSING expected output: '{}'\n", expect);
            return 1;
        }
        return 0;
    }

    // No -serial. QEMU's graphical default is `vc`, a terminal
    // rendered inside the QEMU window. Nothing else writes to it.
    //
    // Turn off every other `vc` default, since each adds a tab in
    // front of the example's output. -parallel none drops the LPT
    // console and -monitor none drops the QEMU monitor, the
    // "compat_monitor0" tab.
    if qemu_has_gtk(qemu) {
        proc_arg(&vm, "-display");
        proc_arg(&vm, "gtk,show-tabs=on");
    }
    proc_arg(&vm, "-parallel");
    proc_arg(&vm, "none");
    proc_arg(&vm, "-monitor");
    proc_arg(&vm, "none");
    if is_kernel {
        // The window opens on the VGA tab, where a kernel example
        // draws its console. The serial0 tab carries the same text.
        // Keystrokes reach the PS/2 keyboard from the VGA tab and
        // COM1 from the serial tab, and con_getc reads either one.
        print(">> qemu (the VGA tab is the kernel's console; close the window to exit)\n");
    } else {
        print(">> qemu (VGA and serial0 tabs in the window; close it to exit)\n");
    }
    ProcResult r = proc_run(&vm);
    i32 rc = r.exit_code;
    proc_result_free(&r);
    return rc;
}

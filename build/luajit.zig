//! Builds LuaJIT from the vendored upstream tarball, replicating the
//! upstream Makefile bootstrap: a host `minilua` runs DynASM to generate
//! `buildvm_arch.h`, a host `buildvm` then emits the VM assembly and the
//! bytecode/library definition headers, and the final static library
//! compiles the interpreter and JIT sources against them.

const std = @import("std");

pub const LuaJit = struct {
    library: *std.Build.Step.Compile,
    /// Upstream `src/` containing lua.h, lauxlib.h, lualib.h, luaconf.h.
    include_dir: std.Build.LazyPath,
    /// Directory containing the generated luajit.h.
    generated_include_dir: std.Build.LazyPath,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) LuaJit {
    const upstream = b.dependency("luajit", .{});
    const arch = target.result.cpu.arch;

    const dasc_file: []const u8, const buildvm_arch_flags: []const []const u8 = switch (arch) {
        .x86_64 => .{
            "src/vm_x64.dasc",
            &.{"-DLUAJIT_TARGET=LUAJIT_ARCH_X64"},
        },
        .aarch64 => .{
            "src/vm_arm64.dasc",
            &.{ "-DLUAJIT_TARGET=LUAJIT_ARCH_arm64", "-DLJ_ARCH_HASFPU=1", "-DLJ_ABI_SOFTFP=0" },
        },
        else => @panic("keywork supports x86_64 and aarch64 Linux"),
    };

    // Host bootstrap interpreter used to run DynASM and genversion.
    const minilua_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .sanitize_c = .off,
    });
    minilua_mod.addCSourceFile(.{ .file = upstream.path("src/host/minilua.c") });
    const minilua = b.addExecutable(.{ .name = "minilua", .root_module = minilua_mod });

    // DynASM: vm_*.dasc -> buildvm_arch.h
    const dynasm_run = b.addRunArtifact(minilua);
    dynasm_run.addFileArg(upstream.path("dynasm/dynasm.lua"));
    dynasm_run.addArgs(&.{ "-D", "ENDIAN_LE" });
    std.debug.assert(target.result.ptrBitWidth() == 64);
    dynasm_run.addArgs(&.{ "-D", "P64", "-D", "JIT", "-D", "FFI" });
    if (arch == .aarch64) dynasm_run.addArgs(&.{ "-D", "DUALNUM", "-D", "FPU", "-D", "HFABI" });
    dynasm_run.addArg("-o");
    const buildvm_arch_h = dynasm_run.addOutputFileArg("buildvm_arch.h");
    dynasm_run.addFileArg(upstream.path(dasc_file));

    // genversion: luajit_rolling.h + .relver -> luajit.h
    const genversion_run = b.addRunArtifact(minilua);
    genversion_run.addFileArg(upstream.path("src/host/genversion.lua"));
    genversion_run.addFileArg(upstream.path("src/luajit_rolling.h"));
    genversion_run.addFileArg(upstream.path(".relver"));
    const luajit_h = genversion_run.addOutputFileArg("luajit.h");

    // Host generator for the VM assembly and definition headers.
    const buildvm_mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .sanitize_c = .off,
    });
    buildvm_mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &.{
            "src/host/buildvm_asm.c",
            "src/host/buildvm_fold.c",
            "src/host/buildvm_lib.c",
            "src/host/buildvm_peobj.c",
            "src/host/buildvm.c",
        },
        .flags = buildvm_arch_flags,
    });
    buildvm_mod.addIncludePath(upstream.path("src"));
    buildvm_mod.addIncludePath(upstream.path("src/host"));
    buildvm_mod.addIncludePath(buildvm_arch_h.dirname());
    buildvm_mod.addIncludePath(luajit_h.dirname());
    const buildvm = b.addExecutable(.{ .name = "buildvm", .root_module = buildvm_mod });
    buildvm.step.dependOn(&dynasm_run.step);
    buildvm.step.dependOn(&genversion_run.step);

    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .unwind_tables = .sync,
        .sanitize_c = .off,
    });

    const def_modes = [_][]const u8{ "bcdef", "ffdef", "libdef", "recdef" };
    inline for (def_modes) |mode| {
        const run = b.addRunArtifact(buildvm);
        run.addArgs(&.{ "-m", mode, "-o" });
        const header = run.addOutputFileArg("lj_" ++ mode ++ ".h");
        for (lib_sources) |file| run.addFileArg(upstream.path(file));
        lib_mod.addIncludePath(header.dirname());
    }

    const folddef_run = b.addRunArtifact(buildvm);
    folddef_run.addArgs(&.{ "-m", "folddef", "-o" });
    const folddef_h = folddef_run.addOutputFileArg("lj_folddef.h");
    folddef_run.addFileArg(upstream.path("src/lj_opt_fold.c"));
    lib_mod.addIncludePath(folddef_h.dirname());

    const ljvm_run = b.addRunArtifact(buildvm);
    ljvm_run.addArgs(&.{ "-m", "elfasm", "-o" });
    const ljvm_s = ljvm_run.addOutputFileArg("lj_vm.S");
    lib_mod.addAssemblyFile(ljvm_s);

    // External frame unwinding: zig's compiler-rt does not provide the
    // _Unwind_* symbols gcc supplies via libgcc, so link libunwind.
    lib_mod.addCMacro("LUAJIT_UNWIND_EXTERNAL", "");
    lib_mod.linkSystemLibrary("unwind", .{});
    lib_mod.addIncludePath(upstream.path("src"));
    lib_mod.addIncludePath(luajit_h.dirname());
    lib_mod.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &(lib_sources ++ core_sources),
    });

    const library = b.addLibrary(.{
        .name = "luajit",
        .root_module = lib_mod,
        .linkage = .static,
    });
    library.step.dependOn(&genversion_run.step);

    return .{
        .library = library,
        .include_dir = upstream.path("src"),
        .generated_include_dir = luajit_h.dirname(),
    };
}

/// Standard library sources; also the input list for the buildvm
/// definition-header modes.
const lib_sources = [_][]const u8{
    "src/lib_base.c",
    "src/lib_math.c",
    "src/lib_bit.c",
    "src/lib_string.c",
    "src/lib_table.c",
    "src/lib_io.c",
    "src/lib_os.c",
    "src/lib_package.c",
    "src/lib_debug.c",
    "src/lib_jit.c",
    "src/lib_ffi.c",
    "src/lib_buffer.c",
};

const core_sources = [_][]const u8{
    "src/lj_assert.c",
    "src/lj_gc.c",
    "src/lj_err.c",
    "src/lj_char.c",
    "src/lj_bc.c",
    "src/lj_obj.c",
    "src/lj_buf.c",
    "src/lj_str.c",
    "src/lj_tab.c",
    "src/lj_func.c",
    "src/lj_udata.c",
    "src/lj_meta.c",
    "src/lj_debug.c",
    "src/lj_prng.c",
    "src/lj_state.c",
    "src/lj_dispatch.c",
    "src/lj_vmevent.c",
    "src/lj_vmmath.c",
    "src/lj_strscan.c",
    "src/lj_strfmt.c",
    "src/lj_strfmt_num.c",
    "src/lj_serialize.c",
    "src/lj_api.c",
    "src/lj_profile.c",
    "src/lj_lex.c",
    "src/lj_parse.c",
    "src/lj_bcread.c",
    "src/lj_bcwrite.c",
    "src/lj_load.c",
    "src/lj_ir.c",
    "src/lj_opt_mem.c",
    "src/lj_opt_fold.c",
    "src/lj_opt_narrow.c",
    "src/lj_opt_dce.c",
    "src/lj_opt_loop.c",
    "src/lj_opt_split.c",
    "src/lj_opt_sink.c",
    "src/lj_mcode.c",
    "src/lj_snap.c",
    "src/lj_record.c",
    "src/lj_crecord.c",
    "src/lj_ffrecord.c",
    "src/lj_asm.c",
    "src/lj_trace.c",
    "src/lj_gdbjit.c",
    "src/lj_ctype.c",
    "src/lj_cdata.c",
    "src/lj_cconv.c",
    "src/lj_ccall.c",
    "src/lj_ccallback.c",
    "src/lj_carith.c",
    "src/lj_clib.c",
    "src/lj_cparse.c",
    "src/lj_lib.c",
    "src/lj_alloc.c",
    "src/lib_aux.c",
    "src/lib_init.c",
};

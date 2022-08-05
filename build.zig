const std = @import("std");
const system_sdk = @import("lib/system_sdk.zig");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zdxc", "src/dxc.zig");
    lib.setBuildMode(mode);
    lib.install();
    // lib.linkSystemLibrary("c");
    lib.linkLibC();
    // lib.linkLibCpp();
    lib.addIncludeDir("lib/directxshadercompiler/include/dxc");
    const target = (std.zig.system.NativeTargetInfo.detect(b.allocator, lib.target) catch unreachable).target;
    const options = Options{ };
    const opt = options.detectDefaults(target);
    _ = buildLibDxcompiler(b, lib, opt);

    // const lib = b.addStaticLibrary("zdxc", "src/main.zig");
    // lib.setBuildMode(mode);
    // lib.install();

    // const target = (std.zig.system.NativeTargetInfo.detect(b.allocator, lib.target) catch unreachable).target;
    // const options = Options{ };
    // const opt = options.detectDefaults(target);
    // linkFromSource(b, lib, opt);

    // const opt = Options {
    //     .from_source = false,
    // };
    // const lib_dxcompiler = buildLibDxcompiler(b, lib, opt);
    // lib.linkLibrary(lib_dxcompiler);

    const main_tests = b.addTest("src/dxc.zig");
    main_tests.setBuildMode(mode);
    // main_tests.linkLibCpp();
    main_tests.linkLibC();
    main_tests.addIncludeDir("lib/directxshadercompiler/include/dxc");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}

pub const Options = struct {
    /// Defaults to X11 on Linux.
    linux_window_manager: ?LinuxWindowManager = null,

    /// Defaults to true on Windows
    d3d12: ?bool = null,

    /// Defaults to true on Darwin
    metal: ?bool = null,

    /// Defaults to true on Linux, Fuchsia
    // TODO(build-system): enable on Windows if we can cross compile Vulkan
    vulkan: ?bool = null,

    /// Defaults to true on Linux
    desktop_gl: ?bool = null,

    /// Defaults to true on Android, Linux, Windows, Emscripten
    // TODO(build-system): not respected at all currently
    opengl_es: ?bool = null,

    /// Whether or not minimal debug symbols should be emitted. This is -g1 in most cases, enough to
    /// produce stack traces but omitting debug symbols for locals. For spirv-tools and tint in
    /// specific, -g0 will be used (no debug symbols at all) to save an additional ~39M.
    ///
    /// When enabled, a debug build of the static library goes from ~947M to just ~53M.
    minimal_debug_symbols: bool = true,

    /// Whether or not to produce separate static libraries for each component of Dawn (reduces
    /// iteration times when building from source / testing changes to Dawn source code.)
    separate_libs: bool = false,

    /// Whether to build Dawn from source or not.
    from_source: bool = false,

    /// The binary release version to use from https://github.com/hexops/mach-gpu-dawn/releases
    binary_version: []const u8 = "release-f90302f",

    /// Detects the default options to use for the given target.
    pub fn detectDefaults(self: Options, target: std.Target) Options {
        const tag = target.os.tag;
        const linux_desktop_like = isLinuxDesktopLike(target);

        var options = self;
        if (options.linux_window_manager == null and linux_desktop_like) options.linux_window_manager = .X11;
        if (options.d3d12 == null) options.d3d12 = tag == .windows;
        if (options.metal == null) options.metal = tag.isDarwin();
        if (options.vulkan == null) options.vulkan = tag == .fuchsia or linux_desktop_like;

        // TODO(build-system): technically Dawn itself defaults desktop_gl to true on Windows.
        if (options.desktop_gl == null) options.desktop_gl = linux_desktop_like;
        options.opengl_es = false; // TODO(build-system): OpenGL ES
        // if (options.opengl_es == null) options.opengl_es = tag == .windows or tag == .emscripten or target.isAndroid() or linux_desktop_like;
        return options;
    }

    pub fn appendFlags(self: Options, flags: *std.ArrayList([]const u8), zero_debug_symbols: bool, is_cpp: bool) !void {
        if (self.minimal_debug_symbols) {
            if (zero_debug_symbols) try flags.append("-g0") else try flags.append("-g1");
        }
        if (is_cpp) try flags.append("-std=c++17");
        if (self.linux_window_manager != null and self.linux_window_manager.? == .X11) try flags.append("-DDAWN_USE_X11");
    }
};

fn linkFromSource(b: *std.build.Builder, step: *std.build.LibExeObjStep, options: Options) void {
    if (options.separate_libs) {
        const lib_dxcompiler = buildLibDxcompiler(b, step, options);
        step.linkLibrary(lib_dxcompiler);
        return;
    }

    var main_abs = std.fs.path.join(b.allocator, &.{ (comptime thisDir()), "src/dummy.zig" }) catch unreachable;
    const lib_dxc = b.addStaticLibrary("lib_dxc", main_abs);
    lib_dxc.install();
    lib_dxc.setBuildMode(step.build_mode);
    lib_dxc.setTarget(step.target);
    lib_dxc.linkLibCpp();
    step.linkLibrary(lib_dxc);

    _ = buildLibDxcompiler(b, lib_dxc, options);
}

pub const LinuxWindowManager = enum {
    X11,
    Wayland,
};

fn isLinuxDesktopLike(target: std.Target) bool {
    const tag = target.os.tag;
    return !tag.isDarwin() and tag != .windows and tag != .fuchsia and tag != .emscripten and !target.isAndroid();
}

fn buildLibDxcompiler(b: *std.build.Builder, step: *std.build.LibExeObjStep, options: Options) *std.build.LibExeObjStep {
    const lib = if (!options.separate_libs) step else blk: {
        var main_abs = std.fs.path.join(b.allocator, &.{ (comptime thisDir()), "src/dawn/dummy.zig" }) catch unreachable;
        const separate_lib = b.addStaticLibrary("dxcompiler", main_abs);
        separate_lib.install();
        separate_lib.setBuildMode(step.build_mode);
        separate_lib.setTarget(step.target);
        separate_lib.linkLibCpp();
        break :blk separate_lib;
    };
    system_sdk.include(b, lib, .{});

    lib.linkSystemLibraryName("oleaut32");
    lib.linkSystemLibraryName("ole32");
    lib.linkSystemLibraryName("dbghelp");
    lib.linkSystemLibraryName("dxguid");
    lib.linkLibCpp();

    var flags = std.ArrayList([]const u8).init(b.allocator);
    flags.appendSlice(&.{
        include("lib/"),
        include("lib/DirectXShaderCompiler/include/llvm/llvm_assert"),
        include("lib/DirectXShaderCompiler/include"),
        include("lib/DirectXShaderCompiler/build/include"),
        include("lib/DirectXShaderCompiler/build/lib/HLSL"),
        include("lib/DirectXShaderCompiler/build/lib/DxilPIXPasses"),
        include("lib/DirectXShaderCompiler/build/include"),
        "-DUNREFERENCED_PARAMETER(x)=",
        "-Wno-inconsistent-missing-override",
        "-Wno-missing-exception-spec",
        "-Wno-switch",
        "-Wno-deprecated-declarations",
        "-Wno-macro-redefined", // regex2.h and regcomp.c requires this for OUT redefinition
        "-DMSFT_SUPPORTS_CHILD_PROCESSES=1",
        "-DHAVE_LIBPSAPI=1",
        "-DHAVE_LIBSHELL32=1",
        "-DLLVM_ON_WIN32=1",
    }) catch unreachable;

    appendLangScannedSources(b, lib, options, .{
        .zero_debug_symbols = true,
        .rel_dirs = &.{
            "lib/DirectXShaderCompiler/lib/Analysis/IPA",
            "lib/DirectXShaderCompiler/lib/Analysis",
            "lib/DirectXShaderCompiler/lib/AsmParser",
            "lib/DirectXShaderCompiler/lib/Bitcode/Writer",
            "lib/DirectXShaderCompiler/lib/DxcBindingTable",
            "lib/DirectXShaderCompiler/lib/DxcSupport",
            "lib/DirectXShaderCompiler/lib/DxilContainer",
            "lib/DirectXShaderCompiler/lib/DxilPIXPasses",
            "lib/DirectXShaderCompiler/lib/DxilRootSignature",
            "lib/DirectXShaderCompiler/lib/DXIL",
            "lib/DirectXShaderCompiler/lib/DxrFallback",
            "lib/DirectXShaderCompiler/lib/HLSL",
            "lib/DirectXShaderCompiler/lib/IRReader",
            "lib/DirectXShaderCompiler/lib/IR",
            "lib/DirectXShaderCompiler/lib/Linker",
            "lib/DirectXShaderCompiler/lib/miniz",
            "lib/DirectXShaderCompiler/lib/Option",
            "lib/DirectXShaderCompiler/lib/PassPrinters",
            "lib/DirectXShaderCompiler/lib/Passes",
            "lib/DirectXShaderCompiler/lib/ProfileData",
            "lib/DirectXShaderCompiler/lib/Target",
            "lib/DirectXShaderCompiler/lib/Transforms/InstCombine",
            "lib/DirectXShaderCompiler/lib/Transforms/IPO",
            "lib/DirectXShaderCompiler/lib/Transforms/Scalar",
            "lib/DirectXShaderCompiler/lib/Transforms/Utils",
            "lib/DirectXShaderCompiler/lib/Transforms/Vectorize",
        },
        .flags = flags.items,
    }) catch unreachable;

    appendLangScannedSources(b, lib, options, .{
        .zero_debug_symbols = true,
        .rel_dirs = &.{
            "lib/DirectXShaderCompiler/lib/Support",
        },
        .flags = flags.items,
        .excluding_contains = &.{
            "DynamicLibrary.cpp", // ignore, HLSL_IGNORE_SOURCES
            "PluginLoader.cpp", // ignore, HLSL_IGNORE_SOURCES
            "Path.cpp", // ignore, LLVM_INCLUDE_TESTS
            "DynamicLibrary.cpp", // ignore
        },
    }) catch unreachable;

    appendLangScannedSources(b, lib, options, .{
        .zero_debug_symbols = true,
        .rel_dirs = &.{
            "lib/DirectXShaderCompiler/lib/Bitcode/Reader",
        },
        .flags = flags.items,
        .excluding_contains = &.{
            "BitReader.cpp", // ignore
        },
    }) catch unreachable;
    return lib;
}

fn appendLangScannedSources(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    options: Options,
    args: struct {
        zero_debug_symbols: bool = false,
        flags: []const []const u8,
        rel_dirs: []const []const u8 = &.{},
        objc: bool = false,
        excluding: []const []const u8 = &.{},
        excluding_contains: []const []const u8 = &.{},
    },
) !void {
    var cpp_flags = std.ArrayList([]const u8).init(b.allocator);
    try cpp_flags.appendSlice(args.flags);
    options.appendFlags(&cpp_flags, args.zero_debug_symbols, true) catch unreachable;
    const cpp_extensions: []const []const u8 = if (args.objc) &.{".mm"} else &.{ ".cpp", ".cc" };
    try appendScannedSources(b, step, .{
        .flags = cpp_flags.items,
        .rel_dirs = args.rel_dirs,
        .extensions = cpp_extensions,
        .excluding = args.excluding,
        .excluding_contains = args.excluding_contains,
    });

    var flags = std.ArrayList([]const u8).init(b.allocator);
    try flags.appendSlice(args.flags);
    options.appendFlags(&flags, args.zero_debug_symbols, false) catch unreachable;
    const c_extensions: []const []const u8 = if (args.objc) &.{".m"} else &.{".c"};
    try appendScannedSources(b, step, .{
        .flags = flags.items,
        .rel_dirs = args.rel_dirs,
        .extensions = c_extensions,
        .excluding = args.excluding,
        .excluding_contains = args.excluding_contains,
    });
}

fn appendScannedSources(b: *std.build.Builder, step: *std.build.LibExeObjStep, args: struct {
    flags: []const []const u8,
    rel_dirs: []const []const u8 = &.{},
    extensions: []const []const u8,
    excluding: []const []const u8 = &.{},
    excluding_contains: []const []const u8 = &.{},
}) !void {
    var sources = std.ArrayList([]const u8).init(b.allocator);
    for (args.rel_dirs) |rel_dir| {
        try scanSources(b, &sources, rel_dir, args.extensions, args.excluding, args.excluding_contains);
    }
    step.addCSourceFiles(sources.items, args.flags);
}

fn scanSources(
    b: *std.build.Builder,
    dst: *std.ArrayList([]const u8),
    rel_dir: []const u8,
    extensions: []const []const u8,
    excluding: []const []const u8,
    excluding_contains: []const []const u8,
) !void {
    const abs_dir = try std.mem.concat(b.allocator, u8, &.{ (comptime thisDir()), "/", rel_dir });
    var dir = try std.fs.openIterableDirAbsolute(abs_dir, .{});
    defer dir.close();
    var dir_it = dir.iterate();
    while (try dir_it.next()) |entry| {
        if (entry.kind != .File) continue;
        var abs_path = try std.fs.path.join(b.allocator, &.{ abs_dir, entry.name });
        abs_path = try std.fs.realpathAlloc(b.allocator, abs_path);

        const allowed_extension = blk: {
            const ours = std.fs.path.extension(entry.name);
            for (extensions) |ext| {
                if (std.mem.eql(u8, ours, ext)) break :blk true;
            }
            break :blk false;
        };
        if (!allowed_extension) continue;

        const excluded = blk: {
            for (excluding) |excluded| {
                if (std.mem.eql(u8, entry.name, excluded)) break :blk true;
            }
            break :blk false;
        };
        if (excluded) continue;

        const excluded_contains = blk: {
            for (excluding_contains) |contains| {
                if (std.mem.containsAtLeast(u8, entry.name, 1, contains)) break :blk true;
            }
            break :blk false;
        };
        if (excluded_contains) continue;

        try dst.append(abs_path);
    }
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

fn include(comptime rel: []const u8) []const u8 {
    return "-I" ++ (comptime thisDir()) ++ "/" ++ rel;
}
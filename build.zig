// INSTRUCTIONS:
// 0) Install Dependencies
//      - Zig (0.11)
//      - JDK: https://www.oracle.com/es/java/technologies/downloads
//      - Android SDK
//          - Also NDK
//          - Also platform tools (for ADB)
// 1) In the next section you will find a set of configuration bits you need to edit
//      - The JDK and Adnroid SDK paths are specially important!
// 2) Obtain a key for signing android APKs (only once)
//      -If you already have a key for signing
//          - Copy the keystore next to this `build.zig` file. The keystore should to be called `android.keystore` (otherwise you can change the keystore.outFileName config accordingly)
//          - Change the `keyAlias` and `password` in the user config section
//      - If you don't have a key:
//          - This build script can generate it for you
//          - You should change the `keystore.dintinguishedName` config section to whatever feels good for your organization/product
//          - The `.keyAlias` is not that important, I think. But `.password`should probably be a strong one.
//          - Run in the cmd line `zig build keystore`
//          - There should be a new `android.keystore` file in the root src directory. (note that eventhough you will see a msg labeled as `error`, it is might be not an error. Looks like the `keytool` print though stderr)
//          - If you try to re-run `zig build keystore` you should get an actual error because `android.keystore` already exists
// 3) Build the APK
//      - Run the cmd `zig build apk`
//      - The built APK is located in the `zig-out` directory
//      - Hint: if you pass the `-Drelease` flag, the resulting APK will be much smaller (~13KB for arm-v7a)
// 4) Install the APK in a device
//      - Enable debugging in you Android device
//      - Connect the device to your PC though USB
//      - Run the cmd `zig build apk_install` (this will also build the APK if needed)
// 5) Run the APK in a device
//      - Make sure you device is connected through USB
//      - Run the cmd `zig build apk_run` (this will also build the APK and install it)

// --- CONFIG: TO BE MODIFIED BY THE USER --------------
const jdk_path = "C:/Program Files/Java/jdk-20";
const androidSdk_rootPath = "C:/Android";
const androidSdk_minVersion = 21;
const androidSdk_targetVersion = 33;
const apkName = "test";
const packageName = "com.organization.test";
const libName = "test";
const keystore = .{
    .outFileName = "android.keystore",
    .keyAlias = "test",
    .password = "androidKSpass",
    .distinguishedName = .{
        // https://stackoverflow.com/questions/3284055/what-should-i-use-for-distinguished-name-in-our-keystore-for-the-android-marke/3284135#3284135
        .commonName = "product.my_organization.com",
        .organizationalUnit = "Unknown",
        .organization = "My Organization",
        .locality = "Unknown", // city/county/town
        .state = "Unknown", // state or province
        .country = "Unknown",
        //.domainComponents = [][]u8{},
    }
};
// ----------------------------------------------------

const std = @import("std");
const builtin = @import("builtin");

const Step = std.Build.Step;
const CrossTarget = std.zig.CrossTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const LazyPath = std.Build.LazyPath;
const CStr = []const u8;

const CpuTargets = struct {
    arm: bool = false,
    arm64: bool = false,
    x86: bool = false,
    x86_64: bool = false,
};
const CpuTarget = std.meta.FieldEnum(CpuTargets);

// --- BUILD ---
pub fn build(b: *std.Build) !void {
    var cpuTargets = CpuTargets {
        .arm = b.option(bool, "arm", "Support arm CPUs") orelse false,
        .arm64 = b.option(bool, "arm64", "Support arm64 CPUs") orelse false,
        .x86 = b.option(bool, "x86", "Support x86 CPUs") orelse false,
        .x86_64 = b.option(bool, "x86_64", "Support x86_64 CPUs") orelse false,
    };
    if(!cpuTargets.arm and !cpuTargets.arm64 and !cpuTargets.x86 and !cpuTargets.x86_64) {
        // if no target was provided assume arm
        cpuTargets.arm = true;
    }

    // find ndk
    const ndk_path = blk: {
        const ndkParent_path = try std.fmt.allocPrint(b.allocator, "{s}/ndk", .{androidSdk_rootPath});
        if(!std.fs.path.isAbsolute(ndkParent_path)) {
            std.log.err("Invalid NDK path: '{s}'", .{ndkParent_path});
            return;
        }
        const ndkParent_dir = try std.fs.openIterableDirAbsolute(ndkParent_path, .{});

        var it = ndkParent_dir.iterate();
        const versionZero = std.SemanticVersion{ .major = 0, .minor = 0, .patch = 0 };
        var highestVersion = versionZero;
        while (try it.next()) |file| {
            if (file.kind != .directory)
                continue;
            const parseResult = std.SemanticVersion.parse(file.name);
            if (parseResult) |version| {
                if (highestVersion.order(version) == .lt) {
                    highestVersion = version;
                }
            } else |_| {}
        }

        break :blk try std.fmt.allocPrint(b.allocator, "{s}/{}", .{ ndkParent_path, highestVersion });
    };

    // find tools paths
    toolsPaths = try ToolsPaths.create(b.allocator);

    // tmp folder for all the files to pack into the APK
    const writeFiles = b.addWriteFiles();

    // make the manifest file
    var manifestTxt = try makeManifestTxt(b.allocator, apkName, std.SemanticVersion{ .major = 2, .minor = 0, .patch = 0 });
    const writeFiles_manifest = b.addWriteFiles();
    const androidManifestPath = writeFiles_manifest.add("AndroidManifest.xml", manifestTxt.items);

    // compile native shared libs
    const optimizeMode = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    inline for(std.meta.fields(CpuTargets)) |cpuTargetField| {
        const cpuTargetEnabled = @field(cpuTargets, cpuTargetField.name);
        const cpuTargetE = @field(CpuTarget, cpuTargetField.name);
        if(cpuTargetEnabled) {
            try addSharedLibStep(b, writeFiles, ndk_path, optimizeMode, cpuTargetE);
        }
    }

    // package with aapt
    const androidJarPath = try std.fmt.allocPrint(b.allocator, "{s}/platforms/android-{}/android.jar", .{ androidSdk_rootPath, androidSdk_minVersion });
    const aaptCmd = b.addSystemCommand(&.{
        toolsPaths.aapt,
        "package",
        "-f",
        "-I",
        androidJarPath,
    });
    aaptCmd.addArg("-M");
    aaptCmd.addFileArg(androidManifestPath);
    aaptCmd.addArg("-F");
    const unalignedApk_path = aaptCmd.addOutputFileArg("test.unaligned.apk");

    aaptCmd.addDirectoryArg(writeFiles.getDirectory());

    // zipalign
    const zipalignCmd = b.addSystemCommand(&.{
        toolsPaths.zipalign,
        "-p", // Page-aligns uncompressed .so files
        "-f", // overwrite existing output file
        "-z", // recompress using the zopfli algorithm, which has better compression ratios but is slower
        "4", // 4 byte alignment
    });
    zipalignCmd.addFileArg(unalignedApk_path);
    const alignedApk_path = zipalignCmd.addOutputFileArg("test.aligned.apk");

    // sign apk
    const copyAlignedApk = b.addWriteFiles();
    const apkToSign_path = copyAlignedApk.addCopyFile(alignedApk_path, "test.apk");
    const minVersionStr = try std.fmt.allocPrint(b.allocator, "{}", .{androidSdk_minVersion});
    const apksignCmd = b.addSystemCommand(&.{
        toolsPaths.apksigner,
        "sign",
        "--ks-key-alias", keystore.keyAlias,
        "--ks", keystore.outFileName,
        "--ks-pass", "pass:" ++ keystore.password,
        "--min-sdk-version", minVersionStr,
    });
    apksignCmd.addFileArg(apkToSign_path);
    const signedApk_path = apkToSign_path;

    const step_apkToOut = b.addInstallFile(signedApk_path, apkName ++ ".apk");
    step_apkToOut.step.dependOn(&apksignCmd.step);

    const requestStep_apk = b.step("apk", "apk");
    requestStep_apk.dependOn(&step_apkToOut.step);

    var step_keystore = BuildKeystoreStep.create(b);
    const requestStep_keystore = b.step("keystore", "keystore");
    requestStep_keystore.dependOn(step_keystore.step());
}
// -------

const FixedAllocator = struct {
    const Self = @This();

    buffer: []u8 = undefined,
    baseAllocator: std.heap.FixedBufferAllocator = undefined,

    fn create(size: usize) !Self {
        var self: Self = undefined;
        self.buffer = try std.heap.page_allocator.alloc(u8, size);
        self.baseAllocator = std.heap.FixedBufferAllocator.init(self.buffer);
        return self;
    }

    fn destroy(self: *Self) void {
        std.heap.page_allocator.free(self.buffer);
    }

    fn allocator(self: *Self) std.mem.Allocator {
        return self.baseAllocator.allocator();
    }
};

const ToolsVersion = struct {
    const Self = @This();
    version: [4]i32 = [4]i32{ -1, -1, -1, -1 },

    fn fromStr(str: []const u8) Self {
        var self = Self{};
        var vi: usize = 0;
        var i: usize = 0;
        while (vi < 4 and i < str.len) {
            // skip non-numeric characters
            while (i < str.len and !std.ascii.isDigit(str[i])) {
                i += 1;
            }
            if (i == str.len) break;

            var x: i32 = 0;
            while (i < str.len and std.ascii.isDigit(str[i])) {
                x *= 10;
                x += str[i] - '0';
                i += 1;
            }
            self.version[vi] = x;
            vi += 1;
        }
        return self;
    }
    fn toStr(self: Self, allocator: std.mem.Allocator) ![]const u8 {
        if (self.version[3] >= 0) {
            return try std.fmt.allocPrint(allocator, "{}.{}.{}-rc{}", .{ self.version[0], self.version[1], self.version[2], self.version[3] });
        } else {
            return try std.fmt.allocPrint(allocator, "{}.{}.{}", .{ self.version[0], self.version[1], self.version[2] });
        }
    }
    fn compare(a: Self, b: Self) std.math.Order {
        for (0..4) |i| {
            if (a.version[i] < b.version[i]) {
                return std.math.Order.lt;
            } else if (a.version[i] > b.version[i]) {
                return std.math.Order.gt;
            }
        }
        return std.math.Order.eq;
    }
};

const ToolsPathMaker = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    fixedAllocator: FixedAllocator,
    buildToolsPath: CStr,
    platformToolsPath: CStr,

    fn create(allocator: std.mem.Allocator) !Self {
        var self: Self = undefined;
        self.allocator = allocator;
        self.fixedAllocator = try FixedAllocator.create(4 << 10);
        errdefer (self.fixedAllocator.destroy());

        const buildToolsPath0 = try std.fs.path.join(self.fixedAllocator.allocator(), &.{ androidSdk_rootPath, "build-tools" });
        if (std.fs.openIterableDirAbsolute(buildToolsPath0, .{})) |dir| {
            var latestVersion = ToolsVersion{};
            {
                var it = dir.iterate();
                while (try it.next()) |subDir| {
                    if (subDir.kind != .directory)
                        continue;
                    const version = ToolsVersion.fromStr(subDir.name);
                    if (version.compare(latestVersion) == .gt) {
                        //std.debug.print("****subDir: {s}\n", .{subDir.name});
                        latestVersion = version;
                    }
                }
            }

            if (latestVersion.compare(ToolsVersion{}) == .eq) {
                return error.buildTools_notInstalled;
            }
            const latestVersionStr = try latestVersion.toStr(self.fixedAllocator.allocator());
            self.buildToolsPath = try std.fs.path.join(self.fixedAllocator.allocator(), &.{ buildToolsPath0, latestVersionStr });
        } else |err| {
            std.log.err("Error opening directory: '{s}'", .{buildToolsPath0});
            return err;
        }

        self.platformToolsPath = try std.fs.path.join(self.fixedAllocator.allocator(), &.{ androidSdk_rootPath, "platform-tools" });
        return self;
    }

    fn destroy(self: Self) void {
        self.fixedAllocator.destroy();
    }

    fn _do(self: Self, root: CStr, name: CStr, ext: CStr) CStr {
        return std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{ root, std.fs.path.sep_str, name, ext }) catch unreachable;
    }
    fn do_build(self: Self, name: CStr, ext: CStr) CStr {
        return self._do(self.buildToolsPath, name, ext);
    }
    fn do_platform(self: Self, name: CStr, ext: CStr) CStr {
        return self._do(self.platformToolsPath, name, ext);
    }
    fn do_jdk(self: Self, name: CStr, ext: CStr) CStr {
        return self._do(jdk_path ++ std.fs.path.sep_str ++ "bin", name, ext);
    }
};

// Contains the paths for the different tools that we will need to build our Android Apk
const ToolsPaths = struct {
    const Self = @This();
    const Str = []const u8;
    const Type = enum { build, platform };

    // build tools
    aapt: Str,
    apksigner: Str,
    zipalign: Str,
    // platform tools
    adb: Str,
    // jdk tools
    keytool: Str,

    fn create(allocator: std.mem.Allocator) !Self {
        var self: Self = undefined;

        const pathMaker = try ToolsPathMaker.create(allocator);

        const ext_exe = if (builtin.os.tag == .windows) ".exe" else "";
        const ext_bat = if (builtin.os.tag == .windows) ".bat" else "";

        self.aapt = pathMaker.do_build("aapt", ext_exe);
        self.apksigner = pathMaker.do_build("apksigner", ext_bat);
        self.zipalign = pathMaker.do_build("zipalign", ext_exe);

        self.adb = pathMaker.do_platform("adb", ext_exe);

        self.keytool = pathMaker.do_jdk("keytool", ext_exe);

        return self;
    }
};
var toolsPaths: ToolsPaths = undefined;

const BuildKeystoreStep = struct {
    const Self = @This();

    b: *std.Build,
    checkStep: Step,
    cmdStep: *Step.Run,
    copyStep: *Step.WriteFile,
    //step: Step,

    fn create(b: *std.Build) *Self {
        var self: *Self = b.allocator.create(Self) catch @panic("OOM");
        self.b = b;

        self.checkStep = Step.init(.{ .id = .custom, .name = "check keystore does not exist already", .owner = b, .makeFn = Self.doCheckStep });

        const dname = keystore.distinguishedName;
        const dnameParam = std.fmt.allocPrint(b.allocator, "CN={s},OU={s},O={s},L={s},ST={s},C={s}", .{dname.commonName, dname.organizationalUnit, dname.organization, dname.locality, dname.state, dname.country}) catch @panic("OOM");
        self.cmdStep = b.addSystemCommand(&.{
            toolsPaths.keytool, "-genkey", "-v",
            "-alias", keystore.keyAlias,
            "-keyalg", "RSA",
            "-keysize", "2048",
            "-validity", "100000",
            "-storepass", keystore.password,
            "-dname", dnameParam,
        });
        self.cmdStep.addArg("-keystore");
        const keystore_tmpPath = self.cmdStep.addOutputFileArg(keystore.outFileName);
        self.cmdStep.step.dependOn(&self.checkStep);

        self.copyStep = b.addWriteFiles();
        self.copyStep.addCopyFileToSource(keystore_tmpPath, keystore.outFileName);
        self.copyStep.step.dependOn(&self.cmdStep.step);

        return self;
    }

    fn doCheckStep(checkStep: *Step, progressNode: *std.Progress.Node) !void {
        _ = progressNode;
        const self = @fieldParentPtr(BuildKeystoreStep, "checkStep", checkStep);
        if (self.b.build_root.handle.access(keystore.outFileName, .{})) {
            std.log.err("'{s}' already exists", .{keystore.outFileName});
            return error.KeysoreAlreadyExists;
        } else |err| {
            switch (err) {
                std.os.AccessError.FileNotFound => {
                    //std.debug.print("OKKKKKKKKKKKKKKK\n", .{});
                    return;
                },
                else => return err,
            }
            err catch return;
        }
    }

    fn step(self: *BuildKeystoreStep) *Step {
        return &self.copyStep.step;
    }
};

fn makeManifestTxt(allocator: std.mem.Allocator, appName: []const u8, glesVersion: ?std.SemanticVersion) !std.ArrayList(u8) {
    var v = try std.ArrayList(u8).initCapacity(allocator, 4 << 10);
    var writer = v.writer();
    try writer.print(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\	package="{[packageName]s}"  
        \\	android:versionCode="1"  
        \\	android:versionName="1.0" >
        \\
        \\	<uses-sdk
        \\		android:minSdkVersion="{[minVersion]}"
        \\		android:targetSdkVersion="{[targetVersion]}" />
        \\
        \\	<application
        \\		android:allowBackup="{[allowBackup]s}"
        //\\		android:icon="@mipmap/icon"
        \\		android:label="{[appName]s}"
        \\		android:hasCode="false">
        \\
        \\		<activity
        \\			android:name="android.app.NativeActivity"
        \\			android:label="{[appName]s}"
        \\			android:configChanges="orientation|keyboardHidden"
        \\			android:exported="true">
        \\			<meta-data
        \\				android:name="android.app.lib_name"
        \\				android:value="{[libName]s}" />
        \\			<intent-filter>
        \\				<action android:name="android.intent.action.MAIN" />
        \\				<category android:name="android.intent.category.LAUNCHER" />
        \\			</intent-filter>
        \\		</activity>
        \\	</application>
        \\
        \\
    , .{
        .appName = appName,
        .libName = libName,
        .packageName = packageName,
        .minVersion = androidSdk_minVersion,
        .targetVersion = androidSdk_targetVersion,
        .allowBackup = "false",
    });

    if (glesVersion) |version| {
        try writer.print("\t<uses-feature android:glEsVersion=\"0x{x:0>4}{x:0>4}\" android:required=\"true\"/>\n", .{ version.major, version.minor });
    }

    try writer.print("\n</manifest>", .{});

    return v;
}

fn makeLibCConfTxt(b: *std.Build, includeDir: []const u8, sysIncludeDir: []const u8, libsDir: []const u8) !std.ArrayList(u8) {
    var arr = try std.ArrayList(u8).initCapacity(b.allocator, 128);
    var writer = arr.writer();
    try writer.print(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
    , .{ includeDir, sysIncludeDir, libsDir });
    return arr;
}

fn addSharedLibStep(b: *std.Build, writeFiles: *Step.WriteFile, ndk_path: CStr, optimizeMode: OptimizeMode, cpuTargetE: CpuTarget) !void {
    const target = CrossTarget{
        .cpu_arch = switch(cpuTargetE) {
            .arm => .arm,
            .arm64 => .aarch64,
            .x86 => .x86,
            .x86_64 => .x86_64,
        },
        .os_tag = .linux,
        .abi = .android
    };
    const outPath = switch(cpuTargetE) {
        .arm => "lib/armeabi-v7a/libtest.so",
        .arm64 => "lib/arm64-v8a/libtest.so",
        .x86 => "lib/x86/libtest.so",
        .x86_64 => "lib/x86_64/libtest.so",
    };
    const llvmPathName = switch(cpuTargetE) {
        .arm => "arm-linux-androideabi",
        .arm64 => "aarch64-linux-android",
        .x86 => "i686-linux-android",
        .x86_64 => "x86_64-linux-android",
    };
    // create a conf file to tell the compiler where to find libC
    const libC_osPath = if(builtin.os.tag == .windows) "windows-x86_64" else "linux-x86_64";
    const libC_rootPath = try std.fmt.allocPrint(b.allocator, "{s}/toolchains/llvm/prebuilt/{s}/sysroot/usr", .{ndk_path, libC_osPath});
    const libC_includePath = try std.fmt.allocPrint(b.allocator, "{s}/include", .{libC_rootPath});
    const libC_includeSysPath = try std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ libC_includePath, llvmPathName });
    const libC_libsPath = try std.fmt.allocPrint(b.allocator, "{s}/lib/{s}/{d}", .{ libC_rootPath, llvmPathName, androidSdk_minVersion });
    const libCConfTxt = try makeLibCConfTxt(b, libC_includePath, libC_includeSysPath, libC_libsPath);
    const libCConfFile = b.addWriteFile("android_libc.conf", libCConfTxt.items);
    //std.debug.print("{s}\n", .{libCConfTxt.items});

    const step_sharedLib = b.addSharedLibrary(std.Build.SharedLibraryOptions{
        .name = libName,
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimizeMode,
    });
    step_sharedLib.step.dependOn(&libCConfFile.step);
    step_sharedLib.setLibCFile(libCConfFile.files.items[0].getPath());
    step_sharedLib.linkLibC();
    step_sharedLib.addLibraryPath(.{ .path = libC_libsPath });
    //step_sharedLib.linkSystemLibraryName("m");
    step_sharedLib.linkSystemLibraryName("dl");
    step_sharedLib.linkSystemLibraryName("log");
    //step_sharedLib.linkSystemLibraryName("mediandk");
    step_sharedLib.linkSystemLibraryName("android");
    step_sharedLib.force_pic = true;
    step_sharedLib.strip = true;
    _ = writeFiles.addCopyFile(step_sharedLib.getEmittedBin(), outPath);
}

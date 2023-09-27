const std = @import("std");
const c = @cImport({
    @cInclude("android/native_activity.h");
    @cInclude("android/log.h");
});

fn dlog(msg: [:0]const u8)void {
    _ = c.__android_log_write(c.ANDROID_LOG_DEBUG, "TUKET_TAG", msg);
}

fn onDestroy(activity: [*c]c.ANativeActivity) callconv(.C) void {
    _ = activity;
    dlog("onDestroy");
}

fn onStart(activity: [*c]c.ANativeActivity) callconv(.C) void {
    _ = activity;
    dlog("onStart");
}

fn onResume(activity: [*c]c.ANativeActivity) callconv(.C) void {
    _ = activity;
    dlog("onResume");
}

fn onSaveInstanceState(activity: [*c]c.ANativeActivity, outLen: [*c]usize) callconv(.C) ?*anyopaque {
    _ = activity;
    dlog("onSaveInstanceState");
    outLen.*= 0;
    return null;
}

fn onPause(activity: [*c]c.ANativeActivity) callconv(.C) void {
    _ = activity;
    dlog("onPause");
}

fn onStop(activity: [*c]c.ANativeActivity) callconv(.C) void {
    _ = activity;
    dlog("onStop");
}

fn onConfigurationChanged(activity: [*c]c.ANativeActivity) callconv(.C) void {
    _ = activity;
    dlog("onConfigurationChanged");
}

fn onLowMemory(activity: [*c]c.ANativeActivity) callconv(.C) void {
    _ = activity;
    dlog("onLowMemory");
}

fn onWindowFocusChanged(activity: [*c]c.ANativeActivity, focused: c_int) callconv(.C) void {
    _ = activity;
    var buffer: [32]u8 = undefined;
    const txt = std.fmt.bufPrintZ(&buffer, "onWindowFocusChanged: {}", .{focused}) catch unreachable;
    dlog(txt);
}

fn onNativeWindowCreated(activity: [*c]c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.C) void {
    _ = window;
    _ = activity;
    dlog("onNativeWindowCreated");
}

fn onNativeWindowDestroyed(activity: [*c]c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.C) void {
    _ = window;
    _ = activity;
    dlog("onNativeWindowDestroyed");
}

fn onInputQueueCreated(activity: [*c]c.ANativeActivity, queue: ?*c.AInputQueue) callconv(.C) void {
    _ = queue;
    _ = activity;
    dlog("onInputQueueCreated");
}

fn onInputQueueDestroyed(activity: [*c]c.ANativeActivity, queue: ?*c.AInputQueue) callconv(.C) void {
    _ = queue;
    _ = activity;
    dlog("onInputQueueDestroyed");
}

fn onNativeWindowRedrawNeeded(activity: [*c]c.ANativeActivity, window: ?*c.ANativeWindow) callconv(.C) void {
    _ = window;
    _ = activity;
    dlog("onNativeWindowRedrawNeeded");
}

export fn ANativeActivity_onCreate(activity: [*c]c.ANativeActivity, savedState: *anyopaque, savedStateSize: usize) void
{
    _ = savedStateSize;
    _ = savedState;

    const callbacks: *c.ANativeActivityCallbacks = activity.*.callbacks;
    callbacks.onDestroy = onDestroy;
    callbacks.onStart = onStart;
    callbacks.onResume = onResume;
    callbacks.onSaveInstanceState = onSaveInstanceState;
    callbacks.onPause = onPause;
    callbacks.onStop = onStop;
    callbacks.onConfigurationChanged = onConfigurationChanged;
    callbacks.onLowMemory = onLowMemory;
    callbacks.onWindowFocusChanged = onWindowFocusChanged;
    callbacks.onNativeWindowCreated = onNativeWindowCreated;
    callbacks.onNativeWindowDestroyed = onNativeWindowDestroyed;
    callbacks.onInputQueueCreated = onInputQueueCreated;
    callbacks.onInputQueueDestroyed = onInputQueueDestroyed;
    callbacks.onNativeWindowRedrawNeeded = onNativeWindowRedrawNeeded;
}
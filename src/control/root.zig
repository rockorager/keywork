//! Private API contract shared by Keywork's control server and client.

pub const interface_name = "dev.rockorager.keywork.compositor";
pub const socket_name = interface_name;
pub const interface_description = @embedFile("control-interface");

pub const Direction = enum { next, previous, left, down, up, right };
pub const WindowTarget = enum { focused };
pub const Layout = enum { tiled };
pub const LogLevel = enum(u8) { @"error", warning, info, debug };

pub const Color = struct {
    red: i64,
    green: i64,
    blue: i64,
    alpha: i64,
};

pub const Border = struct {
    width: i64,
    color: Color,
};

pub const Rectangle = struct {
    x: i64,
    y: i64,
    width: i64,
    height: i64,
};

pub const WindowProtocol = enum { xdg_shell, xwayland };

pub const Window = struct {
    id: []const u8,
    protocol: WindowProtocol,
    title: ?[]const u8 = null,
    appId: ?[]const u8 = null,
    pid: ?i64 = null,
    rect: ?Rectangle = null,
    output: []const u8,
    workspace: i64,
    focused: bool,
    visible: bool,
    floating: bool,
    fullscreen: bool,
    maximized: bool,
    minimized: bool,
};

pub const LatencyStatistics = struct {
    samples: i64 = 0,
    p50Microseconds: i64 = 0,
    p95Microseconds: i64 = 0,
    p99Microseconds: i64 = 0,
    maximumMicroseconds: i64 = 0,
};

pub const DirectScanoutRejections = struct {
    noFullscreenSurface: i64,
    nonOpaqueSurface: i64,
    surfaceTransform: i64,
    nonDmabuf: i64,
    yInverted: i64,
    missingBufferIdentity: i64,
    colorConversion: i64,
    unsupportedBackend: i64,
    outputUnavailable: i64,
    outputBusy: i64,
    deviceInactive: i64,
    unsupportedFormatOrModifier: i64,
    unsupportedLayout: i64,
    framebufferImportFailed: i64,
    pageFlipFailed: i64,
};

pub const OverlayScanoutRejections = struct {
    noTopmostSurface: i64 = 0,
    nonOpaqueSurface: i64 = 0,
    clippedSurface: i64 = 0,
    transformedSurface: i64 = 0,
    scaledSurface: i64 = 0,
    outsideOutput: i64 = 0,
    nonDmabuf: i64 = 0,
    nonRgbSurface: i64 = 0,
    yInverted: i64 = 0,
    missingBufferIdentity: i64 = 0,
    colorConversion: i64 = 0,
    unsupportedBackend: i64 = 0,
    outputUnavailable: i64 = 0,
    outputBusy: i64 = 0,
    deviceInactive: i64 = 0,
    noOverlayPlane: i64 = 0,
    unsupportedFormatOrModifier: i64 = 0,
    unsupportedLayout: i64 = 0,
    synchronizationFailed: i64 = 0,
    framebufferImportFailed: i64 = 0,
    atomicTestFailed: i64 = 0,
    pageFlipFailed: i64 = 0,
};

pub const FramePath = enum { none, composited, direct_scanout, overlay_scanout };
pub const BufferFormat = enum {
    none,
    argb8888,
    xrgb8888,
    abgr8888,
    xbgr8888,
    xrgb2101010,
    rgba16f_linear,
};
pub const OutputTransform = enum { normal };

pub const FrameDiagnostics = struct {
    path: FramePath,
    workingFormat: BufferFormat,
    scanoutFormat: BufferFormat,
    outputTransform: OutputTransform,
    damageRectangles: i64,
    damagedPixels: i64,
};

pub const OutputStatistics = struct {
    name: []const u8,
    width: i64,
    height: i64,
    refreshMillihertz: i64,
    lastFrame: FrameDiagnostics,
    framesRequested: i64,
    framesStarted: i64,
    framesPresented: i64,
    framesDiscarded: i64,
    acquireRetries: i64,
    compositedFrames: i64,
    directScanoutCandidates: i64,
    directScanoutFrames: i64,
    directScanoutRejections: DirectScanoutRejections,
    overlayScanoutCandidates: i64 = 0,
    overlayScanoutFrames: i64 = 0,
    overlayScanoutRejections: OverlayScanoutRejections = .{},
    cpuUploads: i64,
    dmabufImports: i64,
    framesOverBudget: i64,
    gpuExecution: LatencyStatistics,
    gpuComposition: LatencyStatistics,
    gpuPreparation: LatencyStatistics,
    gpuSolidComposition: LatencyStatistics,
    gpuImageComposition: LatencyStatistics,
    gpuShadow: LatencyStatistics,
    gpuBlurDownsample: LatencyStatistics,
    gpuBlurUpsample: LatencyStatistics,
    gpuBlurComposite: LatencyStatistics,
    gpuCompositionOverhead: LatencyStatistics,
    gpuOutputEncode: LatencyStatistics,
    gpuFrameFinish: LatencyStatistics,
    requestToPresentation: LatencyStatistics,
    requestToRender: LatencyStatistics,
    renderToCommit: LatencyStatistics,
    commitToPresentation: LatencyStatistics,
    renderFenceSamples: i64 = 0,
    renderFencesSignaledBeforeCommit: i64 = 0,
    renderToGpuCompletion: LatencyStatistics = .{},
    gpuCompletionToPresentation: LatencyStatistics = .{},
};

pub const ResourceStatistics = struct {
    rendererTargets: i64 = 0,
    pixelRendererTargets: i64 = 0,
    offscreenRendererTargets: i64 = 0,
    dmabufRendererTargets: i64 = 0,
    cachedTextures: i64 = 0,
    importedTextures: i64 = 0,
    pendingTextures: i64 = 0,
    pendingGpuSubmissions: i64 = 0,
    calibrationTextures: i64 = 0,
    videoGraphicsPipelines: i64 = 0,
    blurScratchImages: i64 = 0,
    backdropCacheImages: i64 = 0,
    mappedBufferCapacityBytes: i64 = 0,
    linuxDmabufBuffers: i64 = 0,
    screencopyFrames: i64 = 0,
    imageCopyCaptureSessions: i64 = 0,
    imageCopyCaptureFrames: i64 = 0,
    captureBuffers: i64 = 0,
};

pub const PerformanceStatistics = struct {
    outputs: []const OutputStatistics,
    /// Null when decoding a reply from a compositor predating resource telemetry.
    resources: ?ResourceStatistics = null,
};

pub const focus_method = interface_name ++ ".Focus";
pub const move_focused_method = interface_name ++ ".MoveFocused";
pub const close_method = interface_name ++ ".Close";
pub const toggle_fullscreen_method = interface_name ++ ".ToggleFullscreen";
pub const toggle_floating_method = interface_name ++ ".ToggleFloating";
pub const set_layout_method = interface_name ++ ".SetLayout";
pub const switch_workspace_method = interface_name ++ ".SwitchWorkspace";
pub const move_focused_to_workspace_method = interface_name ++ ".MoveFocusedToWorkspace";
pub const get_windows_method = interface_name ++ ".GetWindows";
pub const get_performance_statistics_method = interface_name ++ ".GetPerformanceStatistics";
pub const set_unfocused_border_method = interface_name ++ ".SetUnfocusedBorder";
pub const set_log_level_method = interface_name ++ ".SetLogLevel";
pub const reload_configuration_method = interface_name ++ ".ReloadConfiguration";
pub const quit_method = interface_name ++ ".Quit";
pub const configuration_reload_failed_error = interface_name ++ ".ConfigurationReloadFailed";

pub const minimum_workspace = 1;
pub const maximum_workspace = 10;

pub fn validWorkspace(workspace: i64) bool {
    return workspace >= minimum_workspace and workspace <= maximum_workspace;
}

pub fn validBorder(border: Border) bool {
    return border.width >= 0 and border.width <= 256 and
        validColorChannel(border.color.red) and
        validColorChannel(border.color.green) and
        validColorChannel(border.color.blue) and
        validColorChannel(border.color.alpha);
}

fn validColorChannel(channel: i64) bool {
    return channel >= 0 and channel <= 255;
}

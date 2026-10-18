import AppKit
import Metal
import MetalKit
import simd
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Combine

/// Metal float3x3 occupies three aligned 16-byte columns. Total stride: 96 bytes.
struct FloatingUniforms {
    var headMatrix: simd_float3x3
    var optics: SIMD4<Float>          // half-FOV tangents, screen half-width/height
    var layout: SIMD4<Float>          // distance, inward angle, gap, unused
    var configuration: SIMD4<UInt32>  // monitor count, valid-texture bitmask, unused
}

/// One transactional capture/render session. UI, GPU encoding and lifecycle live
/// on the main thread; capture callbacks only update the locked frame snapshots.
final class SpatialRenderer: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var fps = 0
    var onFailure: ((Error) -> Void)?

    private let virtualDisplayIDs: [CGDirectDisplayID]
    private let outputDisplayID: CGDirectDisplayID
    private let spatialTracker: SpatialTracker
    let canvasWidth: Int
    let canvasHeight: Int
    var screenDiagonalInches: Float = 65
    var screenDistanceMeters: Float = 2
    var monitorAngleDegrees: Float = 32
    var monitorGapMeters: Float = 0.025

    private var metalDevice: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!
    private var outputWindow: NSWindow?
    private var metalView: MTKView!
    private var mipTextures: [MTLTexture?] = [nil, nil, nil]
    private var blackTexture: MTLTexture?
    private var streams: [SCStream] = []
    private let captureQueue = DispatchQueue(label: "com.ultraxreal.capture", qos: .userInteractive)
    private let frameLock = NSLock()
    private var streamSlots: [ObjectIdentifier: Int] = [:]
    private var currentPixelBuffers: [CVPixelBuffer?] = [nil, nil, nil]
    private var generation: UInt64 = 0
    private var startupTask: Task<Void, Never>?
    private var startupFailure: Error?
    private var stopCompletions: [() -> Void] = []
    private var frameCount = 0
    private var fpsTimer: Timer?
    private var screenObserver: NSObjectProtocol?

    init(virtualDisplayIDs: [CGDirectDisplayID], outputDisplayID: CGDirectDisplayID,
         spatialTracker: SpatialTracker, canvasWidth: Int, canvasHeight: Int) {
        self.virtualDisplayIDs = virtualDisplayIDs
        self.outputDisplayID = outputDisplayID
        self.spatialTracker = spatialTracker
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        super.init()
    }

    convenience init(virtualDisplayID: CGDirectDisplayID, spatialTracker: SpatialTracker,
                     canvasWidth: Int = 1920, canvasHeight: Int = 1080) {
        self.init(virtualDisplayIDs: [virtualDisplayID],
                  outputDisplayID: DisplayMirrorHelper.findXRealDisplay(excludingDisplayID: virtualDisplayID) ?? 0,
                  spatialTracker: spatialTracker, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
    }

    func start() {
        start { [weak self] result in
            if case .failure(let error) = result, !(error is CancellationError) {
                self?.onFailure?(error)
            }
        }
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start(completion: completion) }
            return
        }
        guard !isStopping, startupTask == nil, !isRunning else {
            completion(.failure(SpatialRendererError.sessionBusy))
            return
        }
        guard (1...3).contains(virtualDisplayIDs.count),
              Set(virtualDisplayIDs).count == virtualDisplayIDs.count,
              !virtualDisplayIDs.contains(outputDisplayID), outputDisplayID != 0,
              canvasWidth > 0, canvasHeight > 0 else {
            completion(.failure(SpatialRendererError.invalidConfiguration))
            return
        }
        precondition(MemoryLayout<FloatingUniforms>.stride == 96)
        guard setupMetal() else {
            completion(.failure(SpatialRendererError.metalSetupFailed))
            return
        }
        guard setupOutputWindow() else {
            completion(.failure(SpatialRendererError.outputDisplayNotFound))
            return
        }
        generation &+= 1
        let token = generation
        startupFailure = nil
        observeOutputDisplay(generation: token)
        startupTask = Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try checkStartup(token)
                for (slot, displayID) in virtualDisplayIDs.enumerated() {
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                        throw SpatialRendererError.displayNotFound
                    }
                    let configuration = SCStreamConfiguration()
                    configuration.width = canvasWidth
                    configuration.height = canvasHeight
                    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                    configuration.pixelFormat = kCVPixelFormatType_32BGRA
                    configuration.queueDepth = 3
                    configuration.showsCursor = true
                    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                          configuration: configuration, delegate: self)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
                    streams.append(stream)
                    register(stream, slot: slot)
                    try await stream.startCapture()
                    try checkStartup(token)
                }
                isRunning = true
                metalView?.isPaused = false
                frameCount = 0
                fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self = self] _ in
                    guard let self else { return }
                    self.fps = self.frameCount
                    self.frameCount = 0
                }
                startupTask = nil
                completion(.success(()))
            } catch {
                await closeCaptures()
                tearDownOutput()
                startupTask = nil
                completion(.failure(error))
            }
        }
    }

    private func checkStartup(_ token: UInt64) throws {
        if let startupFailure { throw startupFailure }
        guard generation == token, !isStopping else { throw CancellationError() }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stop(completion: completion) }
            return
        }
        if let completion { stopCompletions.append(completion) }
        guard !isStopping else { return }
        isStopping = true
        generation &+= 1
        isRunning = false
        tearDownOutput()
        let pendingStartup = startupTask
        Task { @MainActor in
            await pendingStartup?.value
            await closeCaptures()
            mipTextures = [nil, nil, nil]
            fps = 0
            isStopping = false
            let completions = stopCompletions
            stopCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    private func tearDownOutput() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        metalView?.isPaused = true
        metalView?.delegate = nil
        outputWindow?.orderOut(nil)
        outputWindow = nil
        metalView = nil
    }

    private func observeOutputDisplay(generation token: UInt64) {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.generation == token, !self.isStopping else { return }
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == self.outputDisplayID
            }) else {
                let error = SpatialRendererError.outputDisplayNotFound
                if self.startupTask != nil {
                    self.startupFailure = error
                } else if self.isRunning {
                    self.stop { [weak self] in
                        guard let self, self.generation == token &+ 1, !self.isStopping else { return }
                        self.onFailure?(error)
                    }
                }
                return
            }
            self.outputWindow?.setFrame(screen.frame, display: true)
            self.metalView?.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
    }

    private func register(_ stream: SCStream, slot: Int) {
        frameLock.lock()
        streamSlots[ObjectIdentifier(stream)] = slot
        frameLock.unlock()
    }

    private func clearFrames() {
        frameLock.lock()
        streamSlots.removeAll()
        currentPixelBuffers = [nil, nil, nil]
        frameLock.unlock()
    }

    @MainActor private func closeCaptures() async {
        let closing = streams
        streams.removeAll()
        clearFrames() // Reject late callbacks before stopping any capture.
        for stream in closing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                stream.stopCapture { _ in continuation.resume() }
            }
            try? stream.removeStreamOutput(self, type: .screen)
        }
    }

    private func setupMetal() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        metalDevice = device

        guard let queue = device.makeCommandQueue() else { return false }
        commandQueue = queue

        // Texture cache for zero-copy IOSurface → MTLTexture
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else { return false }
        self.textureCache = textureCache

        // Build render pipeline
        guard let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "spatialVertex"),
              let fragmentFn = library.makeFunction(name: "spatialFragment") else {
            print("[Renderer] Failed to load Metal shaders")
            return false
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[Renderer] Failed to create pipeline state: \(error)")
            return false
        }

        let fallback = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        fallback.storageMode = .shared
        guard let black = device.makeTexture(descriptor: fallback) else { return false }
        var pixel: UInt32 = 0xFF000000
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                      withBytes: &pixel, bytesPerRow: 4)
        blackTexture = black
        return true
    }

    // MARK: - Output Window

    private func setupOutputWindow() -> Bool {
        guard let xrealScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == outputDisplayID
        }) else {
            print("[Renderer] No XReal Air screen found")
            return false
        }

        let screenFrame = xrealScreen.frame

        metalView = MTKView(frame: CGRect(origin: .zero, size: screenFrame.size),
                            device: metalDevice)
        metalView.delegate = self
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = xrealScreen.maximumFramesPerSecond
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false

        // KeyableBorderlessWindow overrides canBecomeKey/Main → true so MTKView
        // gets active draw callbacks on macOS 26 Tahoe (where the default `false`
        // for borderless windows leaves the render loop suspended).
        let window = KeyableBorderlessWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: xrealScreen
        )
        // Above the shielding window — guaranteed to sit on top of everything,
        // including spaces transitions and Mission Control. `.screenSaver` was
        // demoted on Tahoe and got clamped by the window server.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.contentView = metalView
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovable = false
        window.isExcludedFromWindowsMenu = true
        window.makeKeyAndOrderFront(nil)

        // Force frame *after* orderFront — Tahoe re-clamps borderless windows
        // whose initial contentRect has negative origins (XReal Air sits at
        // global Cocoa coords like (-408, -1080) in our setup). Without this
        // the window lands on the built-in display as a thin strip.
        window.setFrame(screenFrame, display: true)

        outputWindow = window
        return true
    }

}

extension SpatialRenderer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let key = SCStreamFrameInfo.status.rawValue as CFString
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let status = (attachments?.first?[key] as? Int).flatMap(SCFrameStatus.init(rawValue:)) ?? .complete
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        if let slot = streamSlots[ObjectIdentifier(stream)] { currentPixelBuffers[slot] = buffer }
        frameLock.unlock()
    }
}

extension SpatialRenderer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopping,
                  self.streams.contains(where: { $0 === stream }) else { return }
            if self.startupTask != nil {
                self.startupFailure = error
            } else if self.isRunning {
                self.stop { [weak self] in self?.onFailure?(error) }
            }
        }
    }
}

extension SpatialRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self, weak view] in
                if let view { self?.draw(in: view) }
            }
            return
        }
        guard isRunning, view === metalView,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        frameLock.lock()
        let buffers = currentPixelBuffers
        frameLock.unlock()

        var wrappers: [CVMetalTexture] = []
        var validMask: UInt32 = 0
        var textures: [MTLTexture?] = [nil, nil, nil]
        for slot in virtualDisplayIDs.indices {
            guard let buffer = buffers[slot] else { continue }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            var wrapper: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapper)
            guard result == kCVReturnSuccess, let wrapper,
                  let source = CVMetalTextureGetTexture(wrapper) else { continue }
            if mipTextures[slot]?.width != width || mipTextures[slot]?.height != height {
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
                textureDescriptor.usage = [.shaderRead, .renderTarget]
                textureDescriptor.storageMode = .private
                mipTextures[slot] = metalDevice.makeTexture(descriptor: textureDescriptor)
            }
            guard let texture = mipTextures[slot],
                  let blit = commandBuffer.makeBlitCommandEncoder() else { continue }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            wrappers.append(wrapper)
            textures[slot] = texture
            validMask |= 1 << UInt32(slot)
        }

        let state = spatialTracker.presentationState(at: ProcessInfo.processInfo.systemUptime + 0.008)
        let diagonal = max(1, screenDiagonalInches) * 0.0254
        let aspectNorm = Float((16.0 * 16.0 + 9.0 * 9.0).squareRoot())
        var uniforms = FloatingUniforms(
            headMatrix: state.headMatrix,
            optics: SIMD4<Float>(0.369, 0.369 * 9 / 16,
                                 diagonal * 8 / aspectNorm, diagonal * 4.5 / aspectNorm),
            layout: SIMD4<Float>(max(0.1, screenDistanceMeters) / max(0.1, Float(state.zoomLevel)),
                                 min(75, max(0, monitorAngleDegrees)) * .pi / 180,
                                 min(1, max(0, monitorGapMeters)), 0),
            configuration: SIMD4<UInt32>(UInt32(virtualDisplayIDs.count), validMask, 0, 0))
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipelineState)
        for slot in 0..<3 { encoder.setFragmentTexture(textures[slot] ?? blackTexture, index: slot) }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FloatingUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // Metal retains its textures, but not the CV wrappers/IOSurface owners.
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(buffers) {}
            withExtendedLifetime(wrappers) {}
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        frameCount += 1
    }
}

enum SpatialRendererError: LocalizedError {
    case displayNotFound, outputDisplayNotFound, metalSetupFailed, invalidConfiguration, sessionBusy

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "A virtual monitor is unavailable for screen capture."
        case .outputDisplayNotFound: return "The selected XREAL glasses display is no longer connected."
        case .metalSetupFailed: return "Metal could not initialize the spatial renderer."
        case .invalidConfiguration: return "Spatial mode requires one to three distinct virtual monitors and a separate glasses display."
        case .sessionBusy: return "The previous spatial renderer is still starting or stopping."
        }
    }
}

/// Tahoe requires a keyable borderless window to keep display-link rendering active.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

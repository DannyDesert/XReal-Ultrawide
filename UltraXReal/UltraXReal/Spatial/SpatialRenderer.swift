import AppKit
import Metal
import MetalKit
import simd
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Combine
import os

/// Uniform data passed to the Metal fragment shader.
/// Layout must match FloatingUniforms in SpatialShaders.metal.
struct FloatingUniforms {
    var headMatrix: simd_float3x3     // view-space head rotation
    var tanHalfFov: SIMD2<Float>      // glasses half-FOV tangents
    var screenHalfSize: SIMD2<Float>  // floating screen half extents, meters
    var distance: Float               // screen distance in meters
    var _pad0: Float = 0
    var _pad1: SIMD2<Float> = .zero
}

private let renderLog = OSLog(subsystem: "com.ultraxreal.app", category: "Renderer")

/// Captures the virtual display via ScreenCaptureKit, applies head-tracking
/// viewport transform in Metal, and renders to a fullscreen window on the XReal Air.
final class SpatialRenderer: NSObject, ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var fps: Int = 0

    private let virtualDisplayID: CGDirectDisplayID
    private let spatialTracker: SpatialTracker

    // Metal
    private var metalDevice: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var textureCache: CVMetalTextureCache!

    // Display output
    private var outputWindow: NSWindow?
    private var metalView: MTKView!

    // Screen capture
    private var stream: SCStream?
    private var captureQueue = DispatchQueue(label: "com.ultraxreal.capture", qos: .userInteractive)

    // Frame management
    private var currentPixelBuffer: CVPixelBuffer?
    private let frameLock = NSLock()

    // Mipmapped copy of the captured frame. The raycast minifies the screen
    // texture (a 65" screen at 2m covers a fraction of the FOV), and sampling
    // the raw capture with a linear filter aliases badly — crawling text
    // lines. Regenerating mips each frame + trilinear/aniso sampling fixes it.
    private var mipTexture: MTLTexture?

    // FPS counter
    private var frameCount = 0
    private var fpsTimer: Timer?

    // Diagnostics — only mutated from the capture queue, no lock needed.
    private var firstCompleteFrameLogged = false
    private var lastLoggedStatus: SCFrameStatus?

    // Virtual monitor dimensions (pixels, what macOS renders)
    let canvasWidth: Int
    let canvasHeight: Int

    // Floating screen geometry — updatable live from the menu sliders.
    var screenDiagonalInches: Float = 65
    var screenDistanceMeters: Float = 2.0

    // XREAL Air 2 Pro: 46° diagonal FOV, 16:9 → ~40.5° horizontal.
    private let tanHalfFovX: Float = 0.369
    private let tanHalfFovY: Float = 0.369 * 1080.0 / 1920.0

    init(virtualDisplayID: CGDirectDisplayID,
         spatialTracker: SpatialTracker,
         canvasWidth: Int = 1920,
         canvasHeight: Int = 1080) {
        self.virtualDisplayID = virtualDisplayID
        self.spatialTracker = spatialTracker
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - Public

    func start() {
        guard !isRunning else { return }

        guard setupMetal() else {
            print("[Renderer] Failed to set up Metal")
            return
        }

        guard setupOutputWindow() else {
            print("[Renderer] Failed to find XReal Air display for output")
            return
        }

        Task {
            do {
                try await startCapture()
                DispatchQueue.main.async { [weak self] in
                    self?.isRunning = true
                    self?.startFPSCounter()
                }
            } catch {
                print("[Renderer] Failed to start capture: \(error)")
            }
        }
    }

    func stop() {
        isRunning = false
        fpsTimer?.invalidate()
        fpsTimer = nil

        stream?.stopCapture { _ in }
        stream = nil

        metalView?.isPaused = true
        outputWindow?.orderOut(nil)
        outputWindow = nil
        metalView = nil

        frameLock.lock()
        currentPixelBuffer = nil
        frameLock.unlock()
    }

    // MARK: - Metal Setup

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

        return true
    }

    // MARK: - Output Window

    private func setupOutputWindow() -> Bool {
        guard let xrealScreen = findXRealScreen() else {
            print("[Renderer] No XReal Air screen found")
            return false
        }

        let screenFrame = xrealScreen.frame
        print("[Renderer] XReal screen frame=\(screenFrame)")

        metalView = MTKView(frame: CGRect(origin: .zero, size: screenFrame.size),
                            device: metalDevice)
        metalView.delegate = self
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isPaused = false
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

    private func findXRealScreen() -> NSScreen? {
        // Match NSScreen to XReal Air display by CGDirectDisplayID
        if let xrealDisplayID = DisplayMirrorHelper.findXRealDisplay(excludingDisplayID: virtualDisplayID) {
            for screen in NSScreen.screens {
                if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                   screenNumber == xrealDisplayID {
                    return screen
                }
            }
        }

        // Fallback: first external non-builtin screen that isn't our virtual display
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                if CGDisplayIsBuiltin(screenNumber) == 0 && screenNumber != virtualDisplayID {
                    return screen
                }
            }
        }

        return nil
    }

    // MARK: - Screen Capture

    private func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == virtualDisplayID }) else {
            os_log("virtual display %u not in SCShareableContent (%d available)",
                   log: renderLog, type: .error, virtualDisplayID, content.displays.count)
            throw SpatialRendererError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = canvasWidth
        config.height = canvasHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream?.startCapture()
    }

    // MARK: - FPS Counter

    private func startFPSCounter() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = self.frameCount
            self.frameCount = 0
        }
    }
}

// MARK: - SCStreamOutput

extension SpatialRenderer: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // SCK delivers both real frames (status `.complete`, with a pixel
        // buffer) and status-only buffers (`.idle`, `.blank`, `.suspended`)
        // when the captured content isn't changing. An empty virtual display
        // produces only status-only buffers, so we must skip them rather than
        // assume every callback carries a frame.
        let statusKey = SCStreamFrameInfo.status.rawValue as CFString
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let status: SCFrameStatus = (attachments?.first?[statusKey] as? Int).flatMap(SCFrameStatus.init(rawValue:)) ?? .complete

        if status != lastLoggedStatus {
            os_log("SCK status=%{public}@", log: renderLog, type: .info, String(describing: status))
            lastLoggedStatus = status
        }

        guard status == .complete, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if !firstCompleteFrameLogged {
            firstCompleteFrameLogged = true
            os_log("SCK first complete frame %dx%d", log: renderLog, type: .info,
                   CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        }

        frameLock.lock()
        currentPixelBuffer = pixelBuffer
        frameLock.unlock()
    }
}

// MARK: - SCStreamDelegate

extension SpatialRenderer: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[Renderer] Stream stopped: \(error)")
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }
}

// MARK: - MTKViewDelegate

extension SpatialRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        // Get latest captured frame
        frameLock.lock()
        let pixelBuffer = currentPixelBuffer
        frameLock.unlock()

        // Until the first complete frame arrives, draw a dark-grey background
        // so the user can tell the renderer is alive even if SCK is only
        // delivering "idle" status buffers (which happens on a brand-new
        // virtual display with nothing on it yet).
        guard let pixelBuffer else {
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // Zero-copy: create MTLTexture from pixel buffer via CVMetalTextureCache
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )

        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else { return }

        if mipTexture == nil || mipTexture!.width != width || mipTexture!.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            desc.usage = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            mipTexture = metalDevice.makeTexture(descriptor: desc)
        }
        guard let mipTexture else { return }

        // Compute uniforms from tracker state + screen geometry.
        let state = spatialTracker.state

        // Diagonal inches → physical extents in meters (16:9).
        let diagMeters = screenDiagonalInches * 0.0254
        let aspectNorm = Float((16.0 * 16.0 + 9.0 * 9.0).squareRoot())
        let halfW = diagMeters * 16.0 / aspectNorm / 2.0
        let halfH = diagMeters * 9.0 / aspectNorm / 2.0

        // Lean-zoom brings the screen closer instead of cropping pixels.
        let distance = screenDistanceMeters / Float(state.zoomLevel)

        var uniforms = FloatingUniforms(
            headMatrix: state.headMatrix,
            tanHalfFov: SIMD2<Float>(tanHalfFovX, tanHalfFovY),
            screenHalfSize: SIMD2<Float>(halfW, halfH),
            distance: distance
        )

        // Render
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Copy the captured frame into the mip chain and regenerate levels.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: mipTexture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: mipTexture)
            blit.endEncoding()
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(mipTexture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FloatingUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        frameCount += 1
    }
}

// MARK: - Errors

enum SpatialRendererError: Error {
    case displayNotFound
    case metalSetupFailed
    case capturePermissionDenied
}

// MARK: - KeyableBorderlessWindow

/// Borderless NSWindow that can become key/main. Required on macOS 26 Tahoe so
/// MTKView receives active display-link callbacks; without this override the
/// fragment shader runs once and then idles, leaving a black panel.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

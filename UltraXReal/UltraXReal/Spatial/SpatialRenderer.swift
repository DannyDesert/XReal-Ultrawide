import AppKit
import Metal
import MetalKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Combine

/// Viewport uniform data passed to the Metal fragment shader.
struct ViewportUniforms {
    var viewportOrigin: SIMD2<Float>  // normalized [0,1]
    var viewportSize: SIMD2<Float>    // normalized [0,1]
}

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

    // FPS counter
    private var frameCount = 0
    private var fpsTimer: Timer?

    // Canvas dimensions
    let canvasWidth: Int
    let canvasHeight: Int
    let viewportWidth: Int = 1920
    let viewportHeight: Int = 1080

    init(virtualDisplayID: CGDirectDisplayID,
         spatialTracker: SpatialTracker,
         canvasWidth: Int = 3840,
         canvasHeight: Int = 2160) {
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

        metalView = MTKView(frame: CGRect(origin: .zero, size: xrealScreen.frame.size),
                            device: metalDevice)
        metalView.delegate = self
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        outputWindow = NSWindow(
            contentRect: xrealScreen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: xrealScreen
        )
        outputWindow?.level = .screenSaver
        outputWindow?.isOpaque = true
        outputWindow?.backgroundColor = .black
        outputWindow?.contentView = metalView
        outputWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        outputWindow?.makeKeyAndOrderFront(nil)

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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

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

        guard let pixelBuffer else { return }

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

        // Compute viewport uniforms from spatial tracker state
        let state = spatialTracker.state

        let canvasW = Float(canvasWidth)
        let canvasH = Float(canvasHeight)
        let zoomedW = Float(viewportWidth) / Float(state.zoomLevel)
        let zoomedH = Float(viewportHeight) / Float(state.zoomLevel)

        let originX = Float(state.viewportOffset.x) / canvasW
        let originY = Float(state.viewportOffset.y) / canvasH

        var uniforms = ViewportUniforms(
            viewportOrigin: SIMD2<Float>(originX, originY),
            viewportSize: SIMD2<Float>(zoomedW / canvasW, zoomedH / canvasH)
        )

        // Render
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.size, index: 0)
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

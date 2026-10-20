#if os(iOS) || os(macOS)
import MetalKit
import QuartzCore
import SwiftUI
import MelogoldCore
import MelogoldPlayback

/// Живой фон «Сейчас играет» (задание 0031): размытая обложка течёт (верхние частоты), по ней плавают капли её цветов
/// (бас), на ударах размытие собирается — шейдер `FluidShader`, перевод Linux `fluid.frag`. `MTKView`, а не
/// `.layerEffect`: шейдеру нужна текстура обложки 256 × 256 с цепочкой мипов, трилинейной выборкой по уровню и зеркальным
/// повтором, а слой SwiftUI мипов не даёт. Кадр — по часам экрана с его наибольшей частотой (60, 120, 144 Гц), не по
/// таймеру. Движется, пока играет, окно видно, «Живой фон» включён и «Уменьшение движения» выключено; на паузе силы
/// гаснут и кадр замирает, без «Живого фона» — замерший кадр сразу (силы 0, время стоит). Металл недоступен —
/// `NowPlayingBackdrop` рисует фон задания 0030 (`BlurredCoverBackdrop`).
struct FluidBackdropView {
    let cover: NowPlayingCover?
    /// Фон может двигаться: «Живой фон», окно видно, «Уменьшение движения» выключено.
    let live: Bool
    /// Трек играет: время течения идёт, звук слушается.
    let playing: Bool
    /// Новая обложка проявляется поверх старой (без «Уменьшения движения»), иначе сменяется сразу.
    let fades: Bool
    /// Измерение спектра, которое звучит сейчас; `nil` — звука нет (пауза, пульт управляет другим устройством).
    let spectrum: @MainActor () -> SpectrumFrame?

    func makeCoordinator() -> FluidRenderer { FluidRenderer() }

    private func makeView(_ renderer: FluidRenderer) -> FluidMTKView {
        let view = FluidMTKView(frame: .zero, device: FluidPipeline.shared?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.delegate = renderer
        // Пока обложки нет — почти чёрная подложка, как у пустых цветов по долям
        view.clearColor = MTLClearColor(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0, alpha: 1)
        view.onVisibility = { [weak renderer, weak view] in
            guard let renderer, let view else { return }
            renderer.updateLoop(view)
        }
        #if os(macOS)
        // Шейдер пишет значения sRGB как есть (как GL у Linux): без своего цветового пространства macOS их не сопоставит
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #endif
        return view
    }

    private func update(_ view: FluidMTKView, _ renderer: FluidRenderer) {
        renderer.spectrum = spectrum
        renderer.update(cover: cover, live: live, playing: playing, fades: fades, view: view)
    }
}

#if os(macOS)
extension FluidBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> FluidMTKView { makeView(context.coordinator) }
    func updateNSView(_ view: FluidMTKView, context: Context) { update(view, context.coordinator) }
}
#else
extension FluidBackdropView: UIViewRepresentable {
    func makeUIView(context: Context) -> FluidMTKView { makeView(context.coordinator) }
    func updateUIView(_ view: FluidMTKView, context: Context) { update(view, context.coordinator) }
}
#endif

/// `MTKView` с частотой своего экрана: наибольшая частота, какую экран умеет (по умолчанию `MTKView` берёт 60). На Mac
/// ещё следит, видно ли окно: закрытое другим окном или свёрнутое не рисует.
final class FluidMTKView: MTKView {
    var onVisibility: (() -> Void)?

    #if os(macOS)
    private var observers: [any NSObjectProtocol] = []

    var windowVisible: Bool { window?.occlusionState.contains(.visible) ?? false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        matchScreen()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.matchScreen() }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onVisibility?() }
        })
        onVisibility?()
    }

    private func matchScreen() {
        preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? 60
    }
    #else
    var windowVisible: Bool { window != nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        preferredFramesPerSecond = window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        onVisibility?()
    }
    #endif

    func requestFrame() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }
}

/// Униформы шейдера — та же раскладка, что `FluidUniforms` в `FluidShader` (палитра — float4 с выравниванием 16,
/// дальше массивы и числа по 4 байта; размер кратен 16).
private struct FluidUniforms {
    var pal: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var blob: (Float, Float, Float, Float, Float, Float)
    var share: (Float, Float, Float, Float, Float, Float)
    var res: SIMD2<Float>
    var liquid, liquidFlow, lavaFlow, pulse, lavaMix, loud, luma: Float
    var liquidBase, blobScale, zoom, lodBase, lodPulse, bright, sat: Float
    var alpha: Float
    var palCount: Int32
}

/// Устройство, очередь и собранный шейдер — один раз на приложение; `nil` — Metal недоступен или шейдер не собрался
/// (тогда остаётся фон задания 0030). Собирается при первом обращении, поэтому `prepare()` зовут заранее и не из потока
/// интерфейса: сборка исходника — десятки миллисекунд.
nonisolated struct FluidPipeline: Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let state: any MTLRenderPipelineState

    static let shared: FluidPipeline? = make()

    /// Собрать шейдер в фоне, до первого открытия «Сейчас играет».
    static func prepare() async {
        await Task.detached(priority: .utility) { _ = shared }.value
    }

    private static func make() -> FluidPipeline? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            Log.warning("backdrop", "Живой фон недоступен: нет Metal — остаётся размытая обложка")
            return nil
        }
        do {
            let library = try device.makeLibrary(source: FluidShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fluidVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "fluidFragment")
            let color = descriptor.colorAttachments[0]
            color?.pixelFormat = .bgra8Unorm
            // Смена обложки: новая с непрозрачностью `alpha` поверх старой
            color?.isBlendingEnabled = true
            color?.sourceRGBBlendFactor = .sourceAlpha
            color?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color?.sourceAlphaBlendFactor = .one
            color?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return FluidPipeline(device: device, queue: queue, state: try device.makeRenderPipelineState(descriptor: descriptor))
        } catch {
            Log.warning("backdrop", "Живой фон недоступен: шейдер не собрался (\(error.localizedDescription)) — остаётся размытая обложка")
            return nil
        }
    }
}

/// Рисует живой фон: звук → огибающие (`FluidAnalysis`) → движение (`FluidMotion`) → униформы шейдера.
final class FluidRenderer: NSObject, MTKViewDelegate {
    /// Есть ли живой фон. В отладочной сборке `-MelogoldNoShader YES` показывает запасной фон задания 0030.
    static var isAvailable: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MelogoldNoShader") { return false }
        #endif
        return FluidPipeline.shared != nil
    }

    /// Обложка в шейдере: текстура с мипами, яркость, цвета по долям.
    private struct Layer {
        let url: String
        let texture: any MTLTexture
        let luma: Float
        let shares: [ColorShare]
        let base: UInt32
    }

    var spectrum: @MainActor () -> SpectrumFrame? = { nil }
    private var current: Layer?
    private var previous: Layer?
    private var fadeStart: CFTimeInterval = 0
    private var analysis = FluidAnalysis()
    private var motion = FluidMotion()
    private var live = false
    private var playing = false
    private var lastFrame: CFTimeInterval?
    /// Счётчик кадров для отладочной строки журнала: кадры и с какого времени (частота должна быть частотой экрана).
    private var frames: (count: Int, since: CFTimeInterval) = (0, 0)

    func update(cover: NowPlayingCover?, live: Bool, playing: Bool, fades: Bool, view: FluidMTKView) {
        if let cover, cover.url != current?.url, let layer = makeLayer(cover) {
            if let current, fades {
                previous = current
                fadeStart = CACurrentMediaTime()
            } else {
                previous = nil
            }
            current = layer
            view.clearColor = Self.clearColor(layer.base)
        }
        // Замерший кадр: силы 0, время стоит (задание 0031, §6)
        if !live, self.live { motion.freeze() }
        self.live = live
        self.playing = playing
        updateLoop(view)
        view.requestFrame()
    }

    /// Кадры — по часам экрана, пока фон живёт: играет, гаснут силы после паузы или проявляется новая обложка. Иначе цикл
    /// стоит, а кадр рисуется только по запросу (смена обложки, размера, состояния) и остаётся на экране.
    func updateLoop(_ view: FluidMTKView) {
        let fading = previous != nil
        let running = view.windowVisible && (fading || current != nil && live && (playing || !motion.calm))
        guard view.isPaused == running else { return }
        if !running {
            lastFrame = nil
            frames = (0, 0)
        }
        view.enableSetNeedsDisplay = !running
        view.isPaused = !running
        if !running { view.requestFrame() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        (view as? FluidMTKView)?.requestFrame()
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(lastFrame.map { min(max(now - $0, 0), BackdropMotion.longestFrame) } ?? 1.0 / 60)
        lastFrame = now
        guard let fluidView = view as? FluidMTKView else { return }
        let flowing = live && playing && fluidView.windowVisible
        if live {
            if flowing, let frame = spectrum() { analysis.feed(time: frame.time, bands: frame.bands) }
            analysis.step(dt: dt, playing: flowing)
            motion.step(analysis, dt: dt, playing: flowing)
        }
        if now - frames.since >= 5 {
            if frames.since > 0, frames.count > 1 {
                Log.debug("backdrop", "Живой фон: \(Int((Double(frames.count) / (now - frames.since)).rounded())) к/с, бас "
                          + String(format: "%.2f", analysis.bass) + ", верха " + String(format: "%.2f", analysis.high))
            }
            frames = (0, now)
        } else {
            frames.count += 1
        }
        let progress = previous == nil ? 1 : Float(min(1, (now - fadeStart) / BackdropMotion.crossfade))
        if progress >= 1 { previous = nil }
        render(view, progress: progress)
        updateLoop(fluidView)
    }

    private func render(_ view: MTKView, progress: Float) {
        guard let pipeline = FluidPipeline.shared, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let buffer = pipeline.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline.state)
        let size = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        // Старая обложка целиком под новой, которая проявляется: без провала в цвет подложки посередине
        for (layer, alpha) in [(previous, Float(1)), (current, progress)] {
            guard let layer else { continue }
            var uniforms = uniforms(layer, size: size, alpha: alpha)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FluidUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Униформы варианта 1 (задание 0031, §4): силы из движения, постоянные — из задания.
    private func uniforms(_ layer: Layer, size: SIMD2<Float>, alpha: Float) -> FluidUniforms {
        var palette = [SIMD4<Float>](repeating: .zero, count: 6)
        var shares = [Float](repeating: 0, count: 6)
        for (index, color) in layer.shares.prefix(6).enumerated() {
            palette[index] = SIMD4(Float((color.rgb >> 16) & 0xFF) / 255, Float((color.rgb >> 8) & 0xFF) / 255,
                                   Float(color.rgb & 0xFF) / 255, 1)
            shares[index] = Float(color.share)
        }
        let blob = motion.blob
        return FluidUniforms(
            pal: (palette[0], palette[1], palette[2], palette[3], palette[4], palette[5]),
            blob: (blob, blob, blob, blob, blob, blob),
            share: (shares[0], shares[1], shares[2], shares[3], shares[4], shares[5]),
            res: size,
            liquid: motion.liquid, liquidFlow: motion.liquidFlow, lavaFlow: motion.lavaFlow, pulse: motion.pulse,
            lavaMix: 0.55, loud: analysis.loud, luma: layer.luma,
            liquidBase: 0.16, blobScale: 1.0, zoom: 0.02, lodBase: 5.3, lodPulse: 3.0, bright: 1.0, sat: 1.6,
            alpha: alpha, palCount: Int32(min(layer.shares.count, 6)))
    }

    /// Текстура 256 × 256 RGBA с полной цепочкой мипов (стандартное усреднение 2 × 2 — `generateMipmaps`, аналог
    /// `glGenerateMipmap` у Linux).
    private func makeLayer(_ cover: NowPlayingCover) -> Layer? {
        guard let pipeline = FluidPipeline.shared else { return nil }
        let side = ArtworkColors.shaderSide
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = pipeline.device.makeTexture(descriptor: descriptor) else { return nil }
        cover.backdrop.shaderTexture.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: base, bytesPerRow: side * 4)
        }
        guard let buffer = pipeline.queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        buffer.commit()
        return Layer(url: cover.url, texture: texture, luma: Float(cover.backdrop.luma), shares: cover.backdrop.shares,
                     base: cover.backdrop.base)
    }

    private static func clearColor(_ rgb: UInt32) -> MTLClearColor {
        MTLClearColor(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                      blue: Double(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif

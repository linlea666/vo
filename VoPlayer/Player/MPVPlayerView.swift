import AppKit
import Libmpv

/// MoltenVK 的绘制尺寸问题会导致闪烁，这里照 MPVKit 示例做规避：
/// https://github.com/mpv-player/mpv/pull/13651
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

protocol MPVPlayerViewDelegate: AnyObject {
    @MainActor func mpvPropertyChanged(_ name: String, value: Any?)
    @MainActor func mpvFileLoaded()
    @MainActor func mpvPlaybackEnded()
}

/// 承载 libmpv 画面的视图，并封装常用的 mpv 调用。
final class MPVPlayerView: NSView {
    private(set) var metalLayer = MPVMetalLayer()
    private var mpv: OpaquePointer?
    private lazy var eventQueue = DispatchQueue(label: "vo.mpv.events", qos: .userInitiated)
    weak var delegate: MPVPlayerViewDelegate?

    /// 需要观察的属性及格式
    private let observedProperties: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("volume", MPV_FORMAT_DOUBLE),
        ("speed", MPV_FORMAT_DOUBLE),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("video-params/w", MPV_FORMAT_INT64),
        ("video-params/h", MPV_FORMAT_INT64),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
        createMPV()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    // MARK: - 初始化 mpv

    private func createMPV() {
        guard let handle = mpv_create() else {
            NSLog("[VoPlayer] mpv_create 失败")
            return
        }
        mpv = handle

        check(mpv_request_log_messages(handle, "warn"))
        check(mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &metalLayer))
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        setOption("keep-open", "yes")          // 播完停在最后一帧，不关闭
        setOption("idle", "yes")
        setOption("input-media-keys", "yes")
        setOption("ytdl", "no")
        setOption("subs-match-os-language", "yes")
        setOption("subs-fallback", "yes")
        setOption("screenshot-directory", "~/Desktop")

        check(mpv_initialize(handle))

        for (name, format) in observedProperties {
            mpv_observe_property(handle, 0, name, format)
        }

        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            let view = Unmanaged<MPVPlayerView>.fromOpaque(ctx).takeUnretainedValue()
            view.drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// 窗口关闭时调用，释放 mpv。
    func shutdown() {
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        eventQueue.sync {
            mpv_terminate_destroy(handle)
            self.mpv = nil
        }
    }

    deinit {
        shutdown()
    }

    // MARK: - 常用操作

    func loadFile(_ url: URL, startAt seconds: Double? = nil) {
        var args = [url.isFileURL ? url.path : url.absoluteString, "replace"]
        if let seconds, seconds > 0 {
            // mpv 0.38 起 loadfile 第三个参数是 index，选项放第四个
            args += ["-1", "start=\(String(format: "%.3f", seconds))"]
        }
        command("loadfile", args)
    }

    func command(_ name: String, _ args: [String] = []) {
        guard let mpv else { return }
        let all = [name] + args
        var cargs: [UnsafePointer<CChar>?] = all.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        check(mpv_command(mpv, &cargs), context: name)
    }

    func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        check(mpv_set_property_string(mpv, name, value), context: "\(name)=\(value)")
    }

    func setFlag(_ name: String, _ value: Bool) {
        guard let mpv else { return }
        var data: Int32 = value ? 1 : 0
        check(mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data), context: name)
    }

    func setInt(_ name: String, _ value: Int) {
        guard let mpv else { return }
        var data = Int64(value)
        check(mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data), context: name)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        check(mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data), context: name)
    }

    func getDouble(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var data = Double()
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data) >= 0 ? data : nil
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv else { return }
        check(mpv_set_option_string(mpv, name, value), context: "option \(name)")
    }

    private func check(_ status: CInt, context: String = "") {
        if status < 0 {
            NSLog("[VoPlayer] mpv 错误 %@: %@", context, String(cString: mpv_error_string(status)))
        }
    }

    // MARK: - 事件

    private func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv {
                guard let event = mpv_wait_event(mpv, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let raw = event.data else { return }
            let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            let value = Self.decode(property)
            Task { @MainActor in self.delegate?.mpvPropertyChanged(name, value: value) }
        case MPV_EVENT_FILE_LOADED:
            Task { @MainActor in self.delegate?.mpvFileLoaded() }
        case MPV_EVENT_END_FILE:
            Task { @MainActor in self.delegate?.mpvPlaybackEnded() }
        case MPV_EVENT_LOG_MESSAGE:
            if let raw = event.data {
                let msg = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                NSLog("[mpv] %@: %@", String(cString: msg.prefix), String(cString: msg.text))
            }
        default:
            break
        }
    }

    private static func decode(_ property: mpv_event_property) -> Any? {
        guard let data = property.data else { return nil }
        switch property.format {
        case MPV_FORMAT_DOUBLE: return data.assumingMemoryBound(to: Double.self).pointee
        case MPV_FORMAT_FLAG: return data.assumingMemoryBound(to: Int32.self).pointee != 0
        case MPV_FORMAT_INT64: return data.assumingMemoryBound(to: Int64.self).pointee
        case MPV_FORMAT_STRING:
            guard let cstr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
            return String(cString: cstr)
        default: return nil
        }
    }
}

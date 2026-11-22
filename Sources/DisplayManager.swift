import AppKit
import CoreGraphics
import Foundation

/// 포트/순서가 바뀌어도 같은 모니터를 찾기 위한 식별자 (EDID 기반)
struct DisplayIdentity: Codable, Equatable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    init(id: CGDirectDisplayID) {
        vendor = CGDisplayVendorNumber(id)
        model = CGDisplayModelNumber(id)
        serial = CGDisplaySerialNumber(id)
    }
}

struct DisplayInfo {
    let id: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let isMain: Bool
    let isActive: Bool
}

/// 연결 해제 직전의 해상도/위치. 다시 연결할 때 그대로 되돌리는 데 씀.
struct SavedLayout: Codable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double
    let originX: Int32
    let originY: Int32
}

enum DisplayError: Error, CustomStringConvertible {
    case apiUnavailable
    case lastDisplay
    case cgError(String, CGError)

    var description: String {
        switch self {
        case .apiUnavailable: return "디스플레이 제어 API를 찾을 수 없음 (macOS 변경 가능성)"
        case .lastDisplay: return "켜져 있는 디스플레이가 하나뿐이라 끌 수 없음"
        case let .cgError(step, err): return "\(step) 실패 (CGError \(err.rawValue))"
        }
    }
}

final class DisplayManager {
    static let shared = DisplayManager()

    private typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private let configureEnabled: ConfigureEnabledFn?

    private let defaults = UserDefaults.standard
    private let disabledKey = "disabledDisplayIDs"
    private let layoutKeyPrefix = "layout."

    private init() {
        // 비공개 API: 케이블을 뽑은 것처럼 디스플레이를 비활성화/활성화한다.
        let candidates: [(String, String)] = [
            ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLSConfigureDisplayEnabled"),
            ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGSConfigureDisplayEnabled"),
        ]
        var found: ConfigureEnabledFn?
        for (path, symbol) in candidates {
            guard let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, symbol) else { continue }
            found = unsafeBitCast(sym, to: ConfigureEnabledFn.self)
            break
        }
        configureEnabled = found
    }

    var isAvailable: Bool { configureEnabled != nil }

    // MARK: - 조회

    func onlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(
                id: id,
                identity: DisplayIdentity(id: id),
                name: Self.name(for: id),
                isMain: id == main,
                isActive: isActive(id)
            )
        }
    }

    func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    func isActive(_ id: CGDirectDisplayID) -> Bool {
        activeDisplayIDs().contains(id)
    }

    static func name(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               num.uint32Value == id {
                return screen.localizedName
            }
        }
        return "디스플레이 \(id)"
    }

    /// 이 앱이 꺼둔 디스플레이 ID들 (앱 종료/비상 복구 시 다시 켜기 위해 저장)
    var disabledIDs: [CGDirectDisplayID] {
        get { (defaults.array(forKey: disabledKey) as? [NSNumber])?.map { $0.uint32Value } ?? [] }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: disabledKey) }
    }

    // MARK: - 켜기 / 끄기

    func disable(_ id: CGDirectDisplayID) throws {
        let active = activeDisplayIDs()
        guard active.contains(id) else { return } // 이미 꺼져 있음
        guard active.count > 1 else { throw DisplayError.lastDisplay }

        saveLayout(for: id)
        // 하나를 끄면 macOS가 남은 모니터 해상도를 바꿔버리는 경우가 있어 미리 기억해 둠
        let others = snapshotModes(except: id)
        try setEnabled(id, false)
        restoreModes(others, retries: 6)

        var list = disabledIDs
        if !list.contains(id) { list.append(id) }
        disabledIDs = list

        // 안전장치: 혹시라도 켜진 화면이 하나도 없으면 즉시 되돌림
        if activeDisplayIDs().isEmpty {
            try? setEnabled(id, true)
        }
    }

    func enable(_ id: CGDirectDisplayID) throws {
        if !isActive(id) {
            let others = snapshotModes(except: id)
            try setEnabled(id, true)
            restoreModes(others, retries: 6)
        }
        disabledIDs = disabledIDs.filter { $0 != id }
        // 다시 붙은 직후엔 모드 목록이 아직 준비되지 않았을 수 있어서 잠시 기다렸다가 복원
        restoreLayout(for: id, retries: 6)
    }

    /// 이 앱이 꺼둔 모든 디스플레이를 다시 켬
    @discardableResult
    func enableAll() -> [String] {
        var errors: [String] = []
        for id in disabledIDs {
            do { try enable(id) } catch { errors.append("\(id): \(error)") }
        }
        return errors
    }

    private func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) throws {
        guard let configureEnabled else { throw DisplayError.apiUnavailable }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { throw DisplayError.cgError("구성 시작", begin) }
        let err = configureEnabled(config, id, enabled)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.cgError(enabled ? "켜기" : "끄기", err)
        }
        let done = CGCompleteDisplayConfiguration(config, .permanently)
        guard done == .success else { throw DisplayError.cgError("구성 적용", done) }
    }

    // MARK: - 해상도 / 위치 저장·복원

    private func saveLayout(for id: CGDirectDisplayID) {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return }
        let bounds = CGDisplayBounds(id)
        let layout = SavedLayout(
            width: mode.width, height: mode.height,
            pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
            refresh: mode.refreshRate,
            originX: Int32(bounds.origin.x), originY: Int32(bounds.origin.y)
        )
        if let data = try? JSONEncoder().encode(layout) {
            defaults.set(data, forKey: layoutKeyPrefix + key(for: id))
        }
    }

    func savedLayout(for id: CGDirectDisplayID) -> SavedLayout? {
        guard let data = defaults.data(forKey: layoutKeyPrefix + key(for: id)) else { return nil }
        return try? JSONDecoder().decode(SavedLayout.self, from: data)
    }

    private func key(for id: CGDirectDisplayID) -> String {
        let i = DisplayIdentity(id: id)
        return "\(i.vendor)-\(i.model)-\(i.serial)"
    }

    private func restoreLayout(for id: CGDirectDisplayID, retries: Int) {
        guard let saved = savedLayout(for: id) else { return }
        if applyLayout(saved, to: id) || retries <= 0 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restoreLayout(for: id, retries: retries - 1)
        }
    }

    private func layout(of id: CGDirectDisplayID) -> SavedLayout? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        let b = CGDisplayBounds(id)
        return SavedLayout(width: mode.width, height: mode.height,
                           pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                           refresh: mode.refreshRate,
                           originX: Int32(b.origin.x), originY: Int32(b.origin.y))
    }

    private func snapshotModes(except id: CGDirectDisplayID) -> [CGDirectDisplayID: SavedLayout] {
        var result: [CGDirectDisplayID: SavedLayout] = [:]
        for other in activeDisplayIDs() where other != id {
            result[other] = layout(of: other)
        }
        return result
    }

    /// 남아 있는 모니터들의 해상도만 되돌림 (위치는 macOS가 정하도록 둠)
    private func restoreModes(_ snapshot: [CGDirectDisplayID: SavedLayout], retries: Int) {
        var pending: [CGDirectDisplayID: SavedLayout] = [:]
        for (id, saved) in snapshot where !applyLayout(saved, to: id, includeOrigin: false) {
            pending[id] = saved
        }
        guard !pending.isEmpty, retries > 0 else { return }
        if Thread.isMainThread && RunLoop.current.currentMode == nil {
            // CLI처럼 런루프가 돌지 않는 상황: 동기적으로 재시도
            Thread.sleep(forTimeInterval: 0.5)
            restoreModes(pending, retries: retries - 1)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restoreModes(pending, retries: retries - 1)
            }
        }
    }

    /// 저장된 해상도/위치와 같으면 true, 아직 적용할 수 없으면 false
    @discardableResult
    func applyLayout(_ saved: SavedLayout, to id: CGDirectDisplayID, includeOrigin: Bool = true) -> Bool {
        guard isActive(id), let current = CGDisplayCopyDisplayMode(id) else { return false }

        let modeMatches: (CGDisplayMode) -> Bool = { m in
            m.width == saved.width && m.height == saved.height &&
                m.pixelWidth == saved.pixelWidth && m.pixelHeight == saved.pixelHeight &&
                abs(m.refreshRate - saved.refresh) < 0.5
        }
        let bounds = CGDisplayBounds(id)
        let originMatches = !includeOrigin ||
            (Int32(bounds.origin.x) == saved.originX && Int32(bounds.origin.y) == saved.originY)
        if modeMatches(current) && originMatches { return true }

        var targetMode: CGDisplayMode?
        if !modeMatches(current) {
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            targetMode = modes.first(where: modeMatches)
            if targetMode == nil { return false } // 모드 목록이 아직 준비 안 됨 → 재시도
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        if let targetMode {
            CGConfigureDisplayWithDisplayMode(config, id, targetMode, nil)
        }
        if !originMatches {
            CGConfigureDisplayOrigin(config, id, saved.originX, saved.originY)
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}

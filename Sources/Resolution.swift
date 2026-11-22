import CoreGraphics
import Foundation

/// 해상도 선택과 "선호 해상도 유지" (BetterDisplay의 해상도 메뉴 대체)
struct ResolutionOption {
    let mode: CGDisplayMode
    var width: Int { mode.width }
    var height: Int { mode.height }
    var isHiDPI: Bool { mode.pixelWidth > mode.width }
    var refresh: Int { Int(mode.refreshRate.rounded()) }
    var title: String { "\(width) × \(height)" + (isHiDPI ? "  HiDPI" : "") + "  @\(refresh)Hz" }
}

final class Resolution {
    static let shared = Resolution()
    private let defaults = UserDefaults.standard
    private let dm = DisplayManager.shared

    private func key(_ id: CGDirectDisplayID) -> String {
        let i = DisplayIdentity(id: id)
        return "preferred.\(i.vendor)-\(i.model)-\(i.serial)"
    }

    /// 메뉴에 보여줄 해상도 목록: 크기별로 주사율이 가장 높은 것 하나씩, 큰 해상도부터.
    /// 너무 작은 모드는 제외. 현재 쓰는 모드는 항상 포함.
    func options(for id: CGDirectDisplayID) -> [ResolutionOption] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        var best: [String: CGDisplayMode] = [:]
        for m in modes where m.isUsableForDesktopGUI() && m.width >= 1280 {
            let k = "\(m.width)x\(m.height)x\(m.pixelWidth > m.width ? 2 : 1)"
            if let cur = best[k], cur.refreshRate >= m.refreshRate { continue }
            best[k] = m
        }
        if let cur = CGDisplayCopyDisplayMode(id) {
            let k = "\(cur.width)x\(cur.height)x\(cur.pixelWidth > cur.width ? 2 : 1)"
            best[k] = best[k] ?? cur
        }
        // 흐릿한 1x 축소 모드는 숨기고, HiDPI 모드 + 네이티브(가장 큰 1x) + 현재 모드만 표시
        let nativeWidth = best.values.filter { $0.pixelWidth == $0.width }.map(\.width).max() ?? 0
        let current = CGDisplayCopyDisplayMode(id)
        let shown = best.values.filter { m in
            m.pixelWidth > m.width || m.width == nativeWidth || (current.map { Self.same($0, m) } ?? false)
        }
        return shown.map(ResolutionOption.init).sorted {
            ($0.width, $0.isHiDPI ? 1 : 0) > ($1.width, $1.isHiDPI ? 1 : 0)
        }
    }

    func isCurrent(_ option: ResolutionOption, on id: CGDirectDisplayID) -> Bool {
        guard let cur = CGDisplayCopyDisplayMode(id) else { return false }
        return Self.same(cur, option.mode)
    }

    /// 사용자가 메뉴에서 고른 해상도: 적용하고 선호값으로 저장
    @discardableResult
    func choose(_ option: ResolutionOption, on id: CGDirectDisplayID) -> Bool {
        let m = option.mode
        let saved = SavedLayout(width: m.width, height: m.height,
                                pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                                refresh: m.refreshRate, originX: 0, originY: 0)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key(id)) }
        return apply(m, to: id)
    }

    /// 선호값이 없는 모니터는 지금 쓰는 해상도를 선호값으로 삼음 (첫 실행 시)
    func adoptCurrentIfNone() {
        for id in dm.activeDisplayIDs() where preferred(for: id) == nil {
            guard let m = CGDisplayCopyDisplayMode(id) else { continue }
            let saved = SavedLayout(width: m.width, height: m.height,
                                    pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                                    refresh: m.refreshRate, originX: 0, originY: 0)
            if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key(id)) }
        }
    }

    func preferred(for id: CGDirectDisplayID) -> SavedLayout? {
        defaults.data(forKey: key(id)).flatMap { try? JSONDecoder().decode(SavedLayout.self, from: $0) }
    }

    /// 선호 해상도가 있고 지금과 다르면 되돌림. 모드가 아직 없으면 false (재시도용)
    @discardableResult
    func enforcePreferred(on id: CGDirectDisplayID) -> Bool {
        guard let pref = preferred(for: id) else { return true }
        return dm.applyLayout(pref, to: id, includeOrigin: false)
    }

    func enforceAll(retries: Int = 6) {
        let pending = dm.activeDisplayIDs().filter { !enforcePreferred(on: $0) }
        guard !pending.isEmpty, retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.enforceAll(retries: retries - 1)
        }
    }

    private func apply(_ mode: CGDisplayMode, to id: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    static func same(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.width == b.width && a.height == b.height &&
            a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight &&
            abs(a.refreshRate - b.refreshRate) < 0.5
    }
}

final class ResolutionChoice: NSObject {
    let id: CGDirectDisplayID
    let option: ResolutionOption
    init(id: CGDirectDisplayID, option: ResolutionOption) { self.id = id; self.option = option }
}

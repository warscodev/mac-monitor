import CoreGraphics
import Foundation

/// "서브모니터"로 지정된 디스플레이와 현재 모드(듀얼/메인만)를 기억한다.
final class SubMonitor {
    static let shared = SubMonitor()

    private let defaults = UserDefaults.standard
    private let dm = DisplayManager.shared

    private(set) var identity: DisplayIdentity? {
        get { defaults.data(forKey: "sub.identity").flatMap { try? JSONDecoder().decode(DisplayIdentity.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "sub.identity") }
    }
    private(set) var lastID: CGDirectDisplayID? {
        get { (defaults.object(forKey: "sub.lastID") as? NSNumber)?.uint32Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "sub.lastID") }
    }
    private(set) var name: String {
        get { defaults.string(forKey: "sub.name") ?? "서브모니터" }
        set { defaults.set(newValue, forKey: "sub.name") }
    }

    /// 사용자가 마지막으로 고른 모드. true = 메인만
    var wantsMainOnly: Bool {
        get { defaults.bool(forKey: "mode.mainOnly") }
        set { defaults.set(newValue, forKey: "mode.mainOnly") }
    }

    func choose(_ display: DisplayInfo) {
        identity = display.identity
        lastID = display.id
        name = display.name
    }

    /// 처음 실행 시: 메인이 아닌 모니터를 자동 지정 (이름에 C27이 있으면 우선)
    func autoChooseIfNeeded() {
        guard identity == nil else { return }
        let candidates = dm.onlineDisplays().filter { !$0.isMain && $0.isActive }
        if let pick = candidates.first(where: { $0.name.contains("C27") }) ?? candidates.first {
            choose(pick)
        }
    }

    /// 현재 서브모니터의 디스플레이 ID (꺼져 있어도 찾아냄)
    func resolveID() -> CGDirectDisplayID? {
        if let identity, let d = dm.onlineDisplays().first(where: { $0.identity == identity }) {
            if lastID != d.id { lastID = d.id }
            if d.isActive, d.name != name, !d.name.hasPrefix("디스플레이 ") { name = d.name }
            return d.id
        }
        return lastID
    }

    var isActive: Bool {
        guard let id = resolveID() else { return false }
        return dm.isActive(id)
    }

    func turnOff() throws {
        guard let id = resolveID() else { return }
        try dm.disable(id)
    }

    func turnOn() throws {
        guard let id = resolveID() else { return }
        try dm.enable(id)
    }
}

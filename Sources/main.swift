import AppKit

// 인자가 있으면 CLI 모드 (테스트·비상 복구용), 없으면 메뉴바 앱
//   MonitorSwitch list | off | on | enable-all | test
let args = Array(CommandLine.arguments.dropFirst())

func runCLI(_ args: [String]) -> Int32 {
    let dm = DisplayManager.shared
    let sub = SubMonitor.shared
    sub.autoChooseIfNeeded()

    func printState() {
        for d in dm.onlineDisplays() {
            let mode = CGDisplayCopyDisplayMode(d.id)
            let m = mode.map { "\($0.width)x\($0.height) (\($0.pixelWidth)x\($0.pixelHeight)) @\(Int($0.refreshRate))Hz" } ?? "-"
            let b = CGDisplayBounds(d.id)
            print("  id=\(d.id) \(d.name) main=\(d.isMain) active=\(d.isActive) \(m) origin=(\(Int(b.origin.x)),\(Int(b.origin.y)))")
        }
        print("  서브=\(sub.name) id=\(sub.resolveID().map(String.init) ?? "-") active=\(sub.isActive) 저장된꺼짐=\(dm.disabledIDs)")
    }

    do {
        switch args[0] {
        case "list":
            print("API 사용 가능: \(dm.isAvailable)")
            printState()
        case "modes":
            for d in dm.onlineDisplays() where d.isActive {
                print("\(d.name):")
                for o in Resolution.shared.options(for: d.id) {
                    print("  \(Resolution.shared.isCurrent(o, on: d.id) ? "●" : " ") \(o.title)")
                }
            }
        case "off":
            try sub.turnOff(); printState()
        case "on":
            try sub.turnOn()
            RunLoop.main.run(until: Date().addingTimeInterval(4)) // 해상도 복원 재시도 대기
            printState()
        case "enable-all":
            let errs = dm.enableAll()
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            errs.forEach { print("오류: \($0)") }
            printState()
        case "test":
            // 서브를 끄고 5초 뒤 다시 켜서 해상도/위치가 그대로인지 확인
            print("[before]"); printState()
            try sub.turnOff()
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            print("[off]"); printState()
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            try sub.turnOn()
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            print("[on]"); printState()
        default:
            print("사용법: MonitorSwitch [list|modes|off|on|enable-all|test]")
            return 2
        }
    } catch {
        print("오류: \(error)")
        return 1
    }
    return 0
}

if !args.isEmpty && !args[0].hasPrefix("-psn") {
    _ = NSApplication.shared // NSScreen 이름 조회용
    exit(runCLI(args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

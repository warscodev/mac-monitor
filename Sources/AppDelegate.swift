import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let sub = SubMonitor.shared
    private let dm = DisplayManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        sub.autoChooseIfNeeded()
        Resolution.shared.adoptCurrentIfNone()
        knownActive = Set(dm.activeDisplayIDs())

        HotKeys.shared.register(keyCode: kVK_ANSI_M) { [weak self] in self?.toggleMode() }
        HotKeys.shared.register(keyCode: kVK_ANSI_L) { [weak self] in self?.sleepDisplays() }
        HotKeys.shared.register(keyCode: kVK_ANSI_R) { [weak self] in self?.emergencyRestore() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // 지난번에 "메인만" 상태로 끝났다면 그대로 이어감
        if sub.wantsMainOnly {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.applyWantedMode() }
        }
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 앱이 꺼지면 서브모니터가 "사라진" 채로 남지 않도록 복구 (모드 기억은 유지)
        dm.enableAll()
    }

    // MARK: - 동작

    private func toggleMode() {
        sub.wantsMainOnly.toggle()
        applyWantedMode()
    }

    private func applyWantedMode() {
        do {
            if sub.wantsMainOnly {
                if sub.isActive { try sub.turnOff() }
            } else {
                if !sub.isActive { try sub.turnOn() }
            }
        } catch {
            sub.wantsMainOnly = sub.isActive == false
            showError("\(error)")
        }
        updateIcon()
    }

    private func sleepDisplays() {
        // 단축키를 뗄 때의 입력으로 바로 깨지 않게 살짝 늦춤
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        }
    }

    private func emergencyRestore() {
        sub.wantsMainOnly = false
        let errors = dm.enableAll()
        if !sub.isActive { try? sub.turnOn() }
        if !errors.isEmpty { showError(errors.joined(separator: "\n")) }
        updateIcon()
    }

    private var knownActive = Set<CGDirectDisplayID>()

    @objc private func screensChanged() {
        // 새로 나타난 모니터(케이블 재연결, 전원 켬 등)는 선호 해상도로 맞춤
        let now = Set(dm.activeDisplayIDs())
        if !now.subtracting(knownActive).isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Resolution.shared.enforceAll() }
        }
        knownActive = now
        updateIcon()
    }

    @objc private func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Resolution.shared.enforceAll() }
        // 잠자기 후 macOS가 서브모니터를 다시 살려놓는 경우 대비
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.sub.wantsMainOnly, self.sub.isActive else { return }
            self.applyWantedMode()
        }
    }

    // MARK: - 메뉴

    private func updateIcon() {
        let mainOnly = !sub.isActive
        let symbol = mainOnly ? "display" : "display.2"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: mainOnly ? "메인만" : "듀얼")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = mainOnly ? "MonitorSwitch: 메인만" : "MonitorSwitch: 듀얼"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let active = sub.isActive

        let header = NSMenuItem(title: active ? "현재: 듀얼 모니터" : "현재: 메인만 (\(sub.name) 꺼짐)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !dm.isAvailable {
            let warn = NSMenuItem(title: "⚠︎ 디스플레이 제어 API 없음", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        menu.addItem(item(active ? "메인만 쓰기" : "듀얼로 전환", #selector(menuToggle), key: "m"))
        menu.addItem(item("지금 화면 끄기", #selector(menuSleep), key: "l"))

        menu.addItem(.separator())

        for d in dm.onlineDisplays() where d.isActive {
            let res = NSMenuItem(title: "해상도 – \(d.name)", action: nil, keyEquivalent: "")
            let resMenu = NSMenu()
            for opt in Resolution.shared.options(for: d.id) {
                let mi = NSMenuItem(title: opt.title, action: #selector(menuResolution(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ResolutionChoice(id: d.id, option: opt)
                mi.state = Resolution.shared.isCurrent(opt, on: d.id) ? .on : .off
                resMenu.addItem(mi)
            }
            res.submenu = resMenu
            menu.addItem(res)
        }

        menu.addItem(.separator())

        let pick = NSMenuItem(title: "서브모니터 지정", action: nil, keyEquivalent: "")
        let pickMenu = NSMenu()
        let currentID = sub.resolveID()
        for d in dm.onlineDisplays() where d.isActive {
            let title = d.name + (d.isMain ? "  (주 디스플레이)" : "")
            let mi = NSMenuItem(title: title, action: #selector(menuChoose(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = NSNumber(value: d.id)
            mi.state = d.id == currentID ? .on : .off
            pickMenu.addItem(mi)
        }
        if !active {
            let mi = NSMenuItem(title: "\(sub.name) (꺼짐)", action: nil, keyEquivalent: "")
            mi.state = .on
            mi.isEnabled = false
            pickMenu.addItem(mi)
        }
        pick.submenu = pickMenu
        menu.addItem(pick)

        let login = item("로그인 시 자동 실행", #selector(menuLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(item("모든 디스플레이 다시 켜기", #selector(menuRestore), key: "r"))
        menu.addItem(.separator())
        menu.addItem(item("종료", #selector(menuQuit)))
    }

    private func item(_ title: String, _ action: Selector, key: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key ?? "")
        mi.target = self
        if key != nil { mi.keyEquivalentModifierMask = [.control, .option, .command] }
        return mi
    }

    @objc private func menuToggle() { toggleMode() }
    @objc private func menuSleep() { sleepDisplays() }
    @objc private func menuRestore() { emergencyRestore() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuResolution(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ResolutionChoice else { return }
        if !Resolution.shared.choose(choice.option, on: choice.id) {
            showError("해상도 변경 실패: \(choice.option.title)")
        }
    }

    @objc private func menuChoose(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber,
              let d = dm.onlineDisplays().first(where: { $0.id == num.uint32Value }) else { return }
        sub.choose(d)
        updateIcon()
    }

    @objc private func menuLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("자동 실행 설정 실패: \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MonitorSwitch"
        alert.informativeText = message
        alert.runModal()
    }
}

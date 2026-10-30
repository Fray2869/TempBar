// TempBar: minimal menu bar temperature monitor for Apple Silicon Macs.
// Reads the chip's HID temperature sensors (same method as Hot / Stats).
// No network, no admin rights, no files touched.

import Cocoa

// MARK: - Private IOKit HID functions, loaded at runtime with C calling convention

private typealias ClientCreateFn = @convention(c) (OpaquePointer?) -> OpaquePointer?
private typealias SetMatchingFn  = @convention(c) (OpaquePointer, OpaquePointer) -> Int32
private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> OpaquePointer?
private typealias CopyPropertyFn = @convention(c) (OpaquePointer, OpaquePointer) -> OpaquePointer?
private typealias CopyEventFn    = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
private typealias GetFloatFn     = @convention(c) (OpaquePointer, Int32) -> Double

private let kTemperatureEvent: Int64 = 15
private let kTemperatureField: Int32 = 15 << 16

private func loadSymbol<T>(_ lib: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
    guard let sym = dlsym(lib, name) else { return nil }
    return unsafeBitCast(sym, to: type)
}

struct Sensor {
    let name: String
    let celsius: Double
}

final class SensorReader {
    private let client: OpaquePointer
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let productKey: CFString = "Product" as CFString

    // The sensor list and names don't change while running, so fetch them once instead of every read.
    private var servicesArray: CFArray?  // keeps the service objects alive
    private var services: [(name: String, service: OpaquePointer)] = []

    init?() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create       = loadSymbol(lib, "IOHIDEventSystemClientCreate", as: ClientCreateFn.self),
              let setMatching  = loadSymbol(lib, "IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = loadSymbol(lib, "IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = loadSymbol(lib, "IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent    = loadSymbol(lib, "IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let getFloat     = loadSymbol(lib, "IOHIDEventGetFloatValue", as: GetFloatFn.self),
              let client       = create(nil)
        else { return nil }

        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat

        // Only match the temperature sensors (vendor usage page 0xFF00, usage 5).
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        withExtendedLifetime(matching) {
            _ = setMatching(client, OpaquePointer(Unmanaged.passUnretained(matching).toOpaque()))
        }
        refresh()
    }

    func refresh() {
        services = []
        servicesArray = nil
        guard let raw = copyServices(client) else { return }
        let array = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(raw)).takeRetainedValue()
        let keyPtr = OpaquePointer(Unmanaged.passUnretained(productKey).toOpaque())

        for i in 0..<CFArrayGetCount(array) {
            guard let ptr = CFArrayGetValueAtIndex(array, i) else { continue }
            let service = OpaquePointer(ptr)

            guard let nameRaw = copyProperty(service, keyPtr) else { continue }
            let name = Unmanaged<CFString>.fromOpaque(UnsafeRawPointer(nameRaw)).takeRetainedValue() as String
            services.append((name, service))
        }
        servicesArray = array
    }

    // Reads only the sensors whose name passes `include` (all of them by default).
    func read(where include: (String) -> Bool = { _ in true }) -> [Sensor] {
        var result: [Sensor] = []
        for (name, service) in services where include(name) {
            guard let event = copyEvent(service, kTemperatureEvent, 0, 0) else { continue }
            let value = getFloat(event, kTemperatureField)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()

            if value > 0 && value < 150 {
                result.append(Sensor(name: name, celsius: value))
            }
        }
        return result
    }
}

// MARK: - Menu bar app

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let reader = SensorReader()
    private let menu = NSMenu()
    private var sensors: [Sensor] = []
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        startTimer()

        // Nobody can see the menu bar while the display sleeps, so stop polling until it wakes.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    private func startTimer() {
        timer?.invalidate()
        tick()
        let timer = Timer(timeInterval: refreshInterval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 1 // lets macOS batch this wakeup with others
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func screensDidSleep() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func screensDidWake() {
        reader?.refresh() // re-fetch the sensor list in case the whole Mac slept
        startTimer()
    }

    // The title only needs the die sensors; the rest are read when the menu opens.
    @objc private func tick() {
        sensors = reader?.read { $0.contains("tdie") } ?? []
        if sensors.isEmpty { sensors = reader?.read() ?? [] }
        updateTitle()
    }

    private func updateTitle() {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let label = cpuMax.map { String(format: "%.0f°C", $0) } ?? "--°C"
        let title = hot ? "🔥 \(label)" : "🌡 \(label)"
        if statusItem.button?.title != title { statusItem.button?.title = title } // skip redraws when unchanged
    }

    // CPU die sensors are named "tdie" on Apple Silicon; fall back to the hottest sensor otherwise.
    private var dieTemps: [Double] { sensors.filter { $0.name.contains("tdie") }.map(\.celsius) }
    private var cpuMax: Double? { dieTemps.max() ?? sensors.map(\.celsius).max() }
    private var cpuAvg: Double? { dieTemps.isEmpty ? nil : dieTemps.reduce(0, +) / Double(dieTemps.count) }
    private var battery: Double? { sensors.first { $0.name.lowercased().contains("battery") }?.celsius }
    private var ssd: Double? { sensors.filter { $0.name.contains("NAND") }.map(\.celsius).max() }

    private var thermalStateText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious (throttling)"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    // Rebuild the dropdown each time it opens so values are fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        sensors = reader?.read() ?? []
        updateTitle()
        menu.removeAllItems()

        if reader == nil || sensors.isEmpty {
            addInfo("No temperature sensors found", to: menu)
        } else {
            addInfo("CPU (hottest core):  " + fmt(cpuMax), to: menu)
            if cpuAvg != nil { addInfo("CPU (average):  " + fmt(cpuAvg), to: menu) }
            if battery != nil { addInfo("Battery:  " + fmt(battery), to: menu) }
            if ssd != nil { addInfo("SSD:  " + fmt(ssd), to: menu) }
        }

        menu.addItem(.separator())
        addInfo("Thermal state:  " + thermalStateText, to: menu)

        if !sensors.isEmpty {
            menu.addItem(.separator())
            let allItem = NSMenuItem(title: "All sensors (\(sensors.count))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            for s in sensors.sorted(by: { $0.name < $1.name }) {
                addInfo("\(s.name):  \(fmt(s.celsius))", to: sub)
            }
            allItem.submenu = sub
            menu.addItem(allItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit TempBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func addInfo(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        menu.addItem(item)
    }

    private func fmt(_ value: Double?) -> String {
        value.map { String(format: "%.1f°C", $0) } ?? "--"
    }
}

// MARK: - Entry point

// Top-level code isn't main-actor isolated under Swift 6, so enter the main actor explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}

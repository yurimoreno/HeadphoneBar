import AppKit
import IOBluetooth

// MARK: - App Info

let kAppName = "HeadphoneBar"
let kAppVersion = "1.0.2"

// MARK: - Models

struct SavedDevice: Codable, Equatable {
    let address: String
    let name: String

    init(address: String, name: String) {
        self.address = address
        self.name = name
    }

    init?(device: IOBluetoothDevice) {
        guard let address = device.addressString,
              let name = device.name else { return nil }
        self.address = address
        self.name = name
    }
}

// MARK: - Bluetooth Manager

class BluetoothManager: NSObject {
    static let shared = BluetoothManager()

    var onDeviceConnected: (() -> Void)?
    var onDeviceDisconnected: (() -> Void)?

    private var connectedDevices: Set<String> = []

    // MARK: - Get Paired Audio Devices

    func getPairedAudioDevices() -> [IOBluetoothDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        return devices.filter { device in
            let classOfDevice = device.classOfDevice
            let majorClass = (classOfDevice >> 8) & 0x1F

            if majorClass == 4 { // Audio/Video
                return true
            }

            if let name = device.name?.lowercased() {
                let audioKeywords = ["airpods", "headphone", "headset", "speaker", "beats", "buds", "audio", "podcast"]
                return audioKeywords.contains { name.contains($0) }
            }

            return false
        }
    }

    // MARK: - Connect

    func connect(to device: SavedDevice, completion: ((Bool, String?) -> Void)? = nil) {
        guard let ioDevice = IOBluetoothDevice(addressString: device.address) else {
            completion?(false, "Device not found")
            return
        }

        if ioDevice.isConnected() {
            disconnect(from: device) { success in
                completion?(success, nil)
            }
            return
        }

        let result = ioDevice.openConnection()

        DispatchQueue.main.async {
            if result == kIOReturnSuccess {
                self.connectedDevices.insert(device.address)
                self.onDeviceConnected?()
                NotificationCenter.default.post(name: .deviceConnected, object: nil, userInfo: ["device": device])
                completion?(true, nil)
            } else {
                let errorMsg = "Connection failed with error: \(result)"
                completion?(false, errorMsg)
            }
        }
    }

    // MARK: - Disconnect

    func disconnect(from device: SavedDevice, completion: ((Bool) -> Void)? = nil) {
        guard let ioDevice = IOBluetoothDevice(addressString: device.address) else {
            completion?(false)
            return
        }

        let result = ioDevice.closeConnection()

        DispatchQueue.main.async {
            if result == kIOReturnSuccess {
                self.connectedDevices.remove(device.address)
                self.onDeviceDisconnected?()
                NotificationCenter.default.post(name: .deviceDisconnected, object: nil, userInfo: ["device": device])
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }

    // MARK: - Check Connection Status

    func isConnected(address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else {
            return false
        }
        return device.isConnected()
    }

    func isConnected(_ device: SavedDevice) -> Bool {
        return isConnected(address: device.address)
    }
}

// MARK: - Device Manager (Persistence)

class DeviceManager {
    static let shared = DeviceManager()

    private let savedDevicesKey = "SavedDevices"
    private let selectedDeviceKey = "SelectedDevice"

    func getSavedDevices() -> [SavedDevice] {
        guard let data = UserDefaults.standard.data(forKey: savedDevicesKey),
              let devices = try? JSONDecoder().decode([SavedDevice].self, from: data) else {
            return []
        }
        return devices
    }

    func saveDevices(_ devices: [SavedDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: savedDevicesKey)
        }
    }

    func addDevice(_ device: SavedDevice) {
        var devices = getSavedDevices()
        if !devices.contains(device) {
            devices.append(device)
            saveDevices(devices)
        }
    }

    func removeDevice(_ device: SavedDevice) {
        var devices = getSavedDevices()
        devices.removeAll { $0 == device }
        saveDevices(devices)
    }

    func getSelectedDevice() -> SavedDevice? {
        guard let data = UserDefaults.standard.data(forKey: selectedDeviceKey),
              let device = try? JSONDecoder().decode(SavedDevice.self, from: data) else {
            return nil
        }
        return device
    }

    func setSelectedDevice(_ device: SavedDevice?) {
        if let device = device,
           let data = try? JSONEncoder().encode(device) {
            UserDefaults.standard.set(data, forKey: selectedDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedDeviceKey)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let deviceConnected = Notification.Name("deviceConnected")
    static let deviceDisconnected = Notification.Name("deviceDisconnected")
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var deviceSelectionWindow: NSWindow?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupNotifications()

        if DeviceManager.shared.getSavedDevices().isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showDeviceSelection()
            }
        }

        if let lastDevice = DeviceManager.shared.getSelectedDevice() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                BluetoothManager.shared.connect(to: lastDevice) { _, _ in
                    self.updateStatusItemIcon()
                }
            }
        }
    }

    // MARK: - Status Bar Setup

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            updateStatusItemIcon()
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // MARK: - Status Bar Icon

    func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }

        let isConnected = isAnyDeviceConnected()
        let symbolName = isConnected ? "headphones" : "headphones.slash"

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName) {
            button.image = image
            button.image?.isTemplate = true
        }
    }

    func isAnyDeviceConnected() -> Bool {
        let devices = DeviceManager.shared.getSavedDevices()
        return devices.contains { BluetoothManager.shared.isConnected(address: $0.address) }
    }

    func connectedDevice() -> SavedDevice? {
        let devices = DeviceManager.shared.getSavedDevices()
        return devices.first { BluetoothManager.shared.isConnected(address: $0.address) }
    }

    // MARK: - Click Handling

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePrimaryDevice()
        }
    }

    func togglePrimaryDevice() {
        if let device = connectedDevice() {
            BluetoothManager.shared.disconnect(from: device) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemIcon()
                }
            }
        } else if let deviceToConnect = DeviceManager.shared.getSelectedDevice() {
            BluetoothManager.shared.connect(to: deviceToConnect) { [weak self] success, error in
                DispatchQueue.main.async {
                    self?.updateStatusItemIcon()
                    if !success {
                        self?.showAlert(title: "Connection Failed", message: error ?? "Could not connect to \(deviceToConnect.name)")
                    }
                }
            }
        } else {
            showDeviceSelection()
        }
    }

    // MARK: - Context Menu (Right Click)

    func showContextMenu() {
        let menu = NSMenu()

        let devices = DeviceManager.shared.getSavedDevices()
        let selectedDevice = DeviceManager.shared.getSelectedDevice()

        if devices.isEmpty {
            let noDevicesItem = NSMenuItem(title: "No devices configured", action: nil, keyEquivalent: "")
            noDevicesItem.isEnabled = false
            menu.addItem(noDevicesItem)
        } else {
            for device in devices {
                let item = NSMenuItem(title: device.name, action: #selector(connectToDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.state = (selectedDevice == device) ? .on : .off

                if BluetoothManager.shared.isConnected(address: device.address) {
                    item.title = "✓ " + device.name
                }

                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Choose Devices
        let chooseItem = NSMenuItem(title: "Choose Devices...", action: #selector(showDeviceSelection), keyEquivalent: "")
        chooseItem.target = self
        menu.addItem(chooseItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "About HeadphoneBar", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit HeadphoneBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func connectToDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? SavedDevice else { return }

        DeviceManager.shared.setSelectedDevice(device)

        if BluetoothManager.shared.isConnected(address: device.address) {
            BluetoothManager.shared.disconnect(from: device) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemIcon()
                }
            }
        } else {
            BluetoothManager.shared.connect(to: device) { [weak self] success, _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemIcon()
                }
            }
        }
    }

    // MARK: - About Panel

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "HeadphoneBar"
        alert.informativeText = """
        Version: \(kAppVersion)

        One-click Bluetooth headphone connection for macOS.

        Left-click: Connect/disconnect your headphones
        Right-click: Device list and options

        Built with native IOBluetooth framework.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Use SF Symbol as alert icon
        if let iconImage = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones") {
            alert.icon = iconImage
        }

        alert.runModal()
    }

    // MARK: - Device Selection Window

    @objc func showDeviceSelection() {
        if deviceSelectionWindow != nil {
            deviceSelectionWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HeadphoneBar — Choose Devices"
        window.center()

        let viewController = DeviceSelectionViewController()
        viewController.onDismiss = { [weak self] in
            self?.deviceSelectionWindow?.close()
            self?.deviceSelectionWindow = nil
            self?.updateStatusItemIcon()
        }
        window.contentViewController = viewController

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        deviceSelectionWindow = window
    }

    // MARK: - Notifications

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceConnectedNotification),
            name: .deviceConnected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDisconnectedNotification),
            name: .deviceDisconnected,
            object: nil
        )
    }

    @objc func deviceConnectedNotification(_ notification: Notification) {
        DispatchQueue.main.async {
            self.updateStatusItemIcon()
        }
    }

    @objc func deviceDisconnectedNotification(_ notification: Notification) {
        DispatchQueue.main.async {
            self.updateStatusItemIcon()
        }
    }

    // MARK: - Alert Helper

    func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Device Selection View Controller

class DeviceSelectionViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {

    var pairedDevices: [IOBluetoothDevice] = []
    var savedDevices: [SavedDevice] = []

    var tableView: NSTableView!
    var scrollView: NSScrollView!
    var saveButton: NSButton!
    var cancelButton: NSButton!

    var onDismiss: (() -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadDevices()
        setupUI()
    }

    func loadDevices() {
        pairedDevices = BluetoothManager.shared.getPairedAudioDevices()
        savedDevices = DeviceManager.shared.getSavedDevices()
    }

    func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Select devices to show in menu bar:")
        titleLabel.frame = NSRect(x: 20, y: 260, width: 360, height: 20)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        view.addSubview(titleLabel)

        scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: 360, height: 190))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Device"
        nameColumn.width = 280
        tableView.addTableColumn(nameColumn)

        let checkColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("saved"))
        checkColumn.title = "Menu Bar"
        checkColumn.width = 60
        tableView.addTableColumn(checkColumn)

        scrollView.documentView = tableView
        view.addSubview(scrollView)

        for (index, device) in pairedDevices.enumerated() {
            if let saved = SavedDevice(device: device),
               savedDevices.contains(saved) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
            }
        }

        let buttonY: CGFloat = 20

        cancelButton = NSButton(frame: NSRect(x: 200, y: buttonY, width: 80, height: 30))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        view.addSubview(cancelButton)

        saveButton = NSButton(frame: NSRect(x: 290, y: buttonY, width: 90, height: 30))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        view.addSubview(saveButton)
    }

    // MARK: - Table View Data Source

    func numberOfRows(in tableView: NSTableView) -> Int {
        return pairedDevices.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let device = pairedDevices[row]

        if tableColumn?.identifier.rawValue == "name" {
            let textField = NSTextField(labelWithString: device.name ?? "Unknown Device")
            textField.lineBreakMode = .byTruncatingTail
            return textField
        } else if tableColumn?.identifier.rawValue == "saved" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkChanged(_:)))
            check.tag = row
            if let saved = SavedDevice(device: device) {
                check.state = savedDevices.contains(saved) ? .on : .off
            } else {
                check.state = .off
            }
            return check
        }

        return nil
    }

    @objc func checkChanged(_ sender: NSButton) {
        let row = sender.tag
        guard row < pairedDevices.count else { return }

        if sender.state == .on {
            if let saved = SavedDevice(device: pairedDevices[row]) {
                DeviceManager.shared.addDevice(saved)
                savedDevices.append(saved)
            }
        } else {
            if let saved = SavedDevice(device: pairedDevices[row]) {
                DeviceManager.shared.removeDevice(saved)
                savedDevices.removeAll { $0 == saved }
            }
        }
    }

    // MARK: - Actions

    @objc func cancelClicked() {
        onDismiss?()
    }

    @objc func saveClicked() {
        let selectedRows = tableView.selectedRowIndexes
        if let firstSelected = selectedRows.first,
           firstSelected < pairedDevices.count,
           let saved = SavedDevice(device: pairedDevices[firstSelected]) {
            DeviceManager.shared.setSelectedDevice(saved)
        }

        onDismiss?()
    }
}

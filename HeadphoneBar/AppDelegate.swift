import AppKit
import IOBluetooth

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
    private var connectionCallbacks: [String: () -> Void] = [:]

    // MARK: - Get Paired Audio Devices

    func getPairedAudioDevices() -> [IOBluetoothDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        return devices.filter { device in
            // Filter for audio-related device classes
            // Major Class 4 = Audio/Video
            // Minor classes: 0x01 Headphones, 0x02 Hands-free, 0x04 Loudspeaker, 0x06 Microphone
            let classOfDevice = device.classOfDevice
            let majorClass = (classOfDevice >> 8) & 0x1F
            let minorClass = (classOfDevice >> 2) & 0x3F

            if majorClass == 4 { // Audio/Video
                return true
            }

            // Also include devices with "audio" or "headphone" etc in name as fallback
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

        // Check if already connected
        if ioDevice.isConnected() {
            disconnect(from: device) { success in
                completion?(success, nil)
            }
            return
        }

        // Attempt connection
        let result = ioDevice.openConnection()

        if result == kIOReturnSuccess {
            connectedDevices.insert(device.address)
            onDeviceConnected?()
            NotificationCenter.default.post(name: .deviceConnected, object: nil, userInfo: ["device": device])
            completion?(true, nil)
        } else {
            let errorMsg = "Connection failed with error: \(result)"
            completion?(false, errorMsg)
        }
    }

    // MARK: - Disconnect

    func disconnect(from device: SavedDevice, completion: ((Bool) -> Void)? = nil) {
        guard let ioDevice = IOBluetoothDevice(addressString: device.address) else {
            completion?(false)
            return
        }

        let result = ioDevice.closeConnection()

        if result == kIOReturnSuccess {
            connectedDevices.remove(device.address)
            onDeviceDisconnected?()
            NotificationCenter.default.post(name: .deviceDisconnected, object: nil, userInfo: ["device": device])
            completion?(true)
        } else {
            completion?(false)
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

    // Add a device to the saved list if not already there
    func ensureDeviceSaved(_ device: IOBluetoothDevice) {
        guard let saved = SavedDevice(device: device) else { return }
        addDevice(saved)
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
    var popover: NSPopover?

    // Device selection window
    var deviceSelectionWindow: NSWindow?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupNotifications()

        // Check if first launch (no saved devices)
        if DeviceManager.shared.getSavedDevices().isEmpty {
            // Show device selection immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showDeviceSelection()
            }
        }

        // Auto-connect to last selected device
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

    func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }

        let isConnected = isAnyDeviceConnected()

        // Use SF Symbols if available, fallback to system image
        if #available(macOS 11.0, *) {
            let symbolName = isConnected ? "headphones" : "headphones"
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Headphones") {
                let configured = image.withSymbolConfiguration(config)
                button.image = configured
                button.image?.isTemplate = true
            }
        } else {
            // Fallback: use a simple text icon
            button.title = isConnected ? "🎧" : "🎧"
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
            // Left click: toggle connection of primary device
            togglePrimaryDevice()
        }
    }

    func togglePrimaryDevice() {
        if let device = connectedDevice() {
            // Disconnect if connected
            BluetoothManager.shared.disconnect(from: device) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItemIcon()
                }
            }
        } else if let deviceToConnect = DeviceManager.shared.getSelectedDevice() {
            // Connect to selected device
            BluetoothManager.shared.connect(to: deviceToConnect) { [weak self] success, error in
                DispatchQueue.main.async {
                    self?.updateStatusItemIcon()
                    if !success {
                        self?.showNotification(title: "Connection Failed", body: error ?? "Could not connect to \(deviceToConnect.name)")
                    }
                }
            }
        } else {
            // No device selected, show selection
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
            // Add devices
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

        // Update selected device
        DeviceManager.shared.setSelectedDevice(device)

        // Toggle connection
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

    func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
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
        // Title label
        let titleLabel = NSTextField(labelWithString: "Select devices to show in menu bar:")
        titleLabel.frame = NSRect(x: 20, y: 260, width: 360, height: 20)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        view.addSubview(titleLabel)

        // Table view
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

        // Pre-select saved devices
        for (index, device) in pairedDevices.enumerated() {
            if let saved = SavedDevice(device: device),
               savedDevices.contains(saved) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: true)
            }
        }

        // Buttons
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
        // Set the first selected device as the primary
        let selectedRows = tableView.selectedRowIndexes
        if let firstSelected = selectedRows.first,
           firstSelected < pairedDevices.count,
           let saved = SavedDevice(device: pairedDevices[firstSelected]) {
            DeviceManager.shared.setSelectedDevice(saved)
        }

        onDismiss?()
    }
}

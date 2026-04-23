# HeadphoneBar — Spec

## Overview
macOS menu bar app for one-click Bluetooth headphone connection. Lightweight, fast, no fluff.

## Functionality

### Core Features
1. **Device Selection** — First launch shows paired Bluetooth audio devices (headphones, speakers). User selects which devices to show in the menu bar.
2. **One-Click Connect** — Click a device in the menu bar to connect. Click again to disconnect.
3. **Status Display** — Menu bar icon shows connection state. Filled icon = connected, hollow = disconnected.
4. **Persistence** — Selected devices persist across restarts.
5. **Auto-connect on launch** — Connects to last connected device on app startup (optional, can be disabled).
6. **Dock icon hidden** — App lives only in the menu bar.

### Menu Bar Behavior
- **Left-click**: Connect/disconnect selected device
- **Right-click**: Show device list and preferences
  - List of saved devices with connection status
  - "Choose Devices..." option to rescan
  - "Quit"

### Preferences
- Device list management (add/remove from menu bar)
- Auto-connect toggle
- Launch at login toggle

## Technical

- **Language**: Swift
- **Framework**: AppKit (NSStatusItem, NSMenu), IOBluetooth
- **Architecture**: Simple MVC, single-file main app
- **Storage**: UserDefaults for preferences, selected devices
- **Bluetooth**: IOBluetooth framework for device discovery and connection

## Scope (MVP)
- ✅ One-click connect/disconnect
- ✅ Menu bar icon with status
- ✅ Multi-device support (user selects which to show)
- ✅ Preferences (device management)
- ❌ Battery percentage display (future)
- ❌ Global hotkeys (future)
- ❌ Script hooks (future)
- ❌ Audio quality / codec switching (future)

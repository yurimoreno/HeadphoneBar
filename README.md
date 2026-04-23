# HeadphoneBar

One-click Bluetooth headphone connection for macOS. Menu bar app, no fluff.

## Features

- Connect/disconnect Bluetooth headphones with one click from the menu bar
- Left-click to toggle connection
- Right-click to see all saved devices and preferences
- Shows connection status via icon (filled = connected, hollow = disconnected)
- Supports multiple devices
- Auto-connects to last used device on launch
- Lives only in the menu bar — no Dock icon

## Requirements

- macOS 10.15 (Catalina) or later
- Bluetooth headphones, speakers, or any paired audio device

## Installation

### Option 1: Build from source

```bash
# Clone the repo
git clone https://github.com/yurimoreno/HeadphoneBar.git
cd HeadphoneBar

# Generate the Xcode project
xcodegen generate

# Build
xcodebuild -project HeadphoneBar.xcodeproj -scheme HeadphoneBar -configuration Release build
```

The built app will be at:
```
~/Library/Developer/Xcode/DerivedData/HeadphoneBar-*/Build/Products/Release/HeadphoneBar.app
```

### Option 2: Copy to Applications

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/HeadphoneBar-*/Build/Products/Release/HeadphoneBar.app /Applications/
```

Then launch it from `/Applications/HeadphoneBar.app` or spotlight.

### Option 3: Launch at login

After copying to `/Applications/`, enable launch at login in the app's right-click menu, or use:

```bash
open -a HeadphoneBar
```

## Usage

1. Launch HeadphoneBar — a device selection window will open
2. Check the Bluetooth devices you want to manage
3. Click **Save**
4. Click the headphones icon in the menu bar to connect/disconnect
5. Right-click for device management

## How it works

- Uses native `IOBluetooth` framework — no third-party dependencies
- `LSUIElement = YES` hides the Dock icon
- Device selection and preferences stored in `UserDefaults`

## Roadmap

- Battery percentage display
- Global hotkeys
- Script hooks on connect/disconnect
- Audio quality / codec switching

## License

MIT

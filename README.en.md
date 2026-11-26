# DeskLink

[Русский](README.md)

DeskLink lets you control your Mac's current desktop session from an iPhone or iPad. The project includes an iOS 18+ client and the DeskLink Host app for macOS 15+.

The client supports direct touch, trackpad mode, an on-screen keyboard with shortcuts, Mac audio, a shared text clipboard, and switching between displays.

## Connect to your Mac

1. Open DeskLink Host on your Mac. Grant it Screen & System Audio Recording and Accessibility permissions in System Settings. Restart the host if macOS asks you to.
2. Click “Включить доступ” (Enable access). Keep the Mac awake and signed in.
3. Connect your iPhone or iPad to the same Wi-Fi network. In DeskLink, tap “Добавить Mac” (Add Mac) and scan the QR code on the Mac. Allow camera and local network access.
4. Tap the saved Mac to connect. Tap to click, scroll with two fingers, and tap with two fingers to right-click. Touch and hold, then move to drag. Pinch to zoom. Use the top bar to switch to trackpad mode or show the keyboard. The ellipsis menu contains audio, clipboard, and display controls.

To connect over a personal VPN, use your Mac's VPN address in the saved connection. DeskLink defaults to the Mac's local hostname. If it does not resolve, enter the Mac's local IP address. DeskLink uses TCP port 49169 and TLS 1.3. The client verifies the Mac's certificate fingerprint from the pairing code. The QR code includes the access key. Use “Сменить ключ доступа” (Rotate access key) to revoke existing pairings.

## macOS menu bar

Click “Свернуть в строку меню” (Minimize to the menu bar) or close the DeskLink Host window. The host keeps running and the active remote session stays connected. Click the monitor icon in the macOS menu bar and choose “Показать окно” (Show window) to reopen the settings and QR code. You can also enable access, disable access, or quit the host from this menu.

## Build and install from Xcode

Open `DeskLink.xcodeproj`. Use the `DeskLink Host` scheme to build the Mac app. To install the client, select the `DeskLink` scheme, add your Apple Account to Xcode, select your team under Signing & Capabilities, and run on a connected iPhone or iPad with Developer Mode enabled.

If Xcode cannot register the app identifier with your team, set a unique Bundle Identifier for the `DeskLink` target. The project uses Apple system frameworks and requires no third-party packages.

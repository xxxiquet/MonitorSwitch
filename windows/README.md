# MonitorSwitch for Windows

A tray app that follows the physical Logitech Easy-Switch buttons and switches a shared monitor. No account, subscription, Windows service or administrator privileges are required.

## Setup

1. Pair the keyboard with the device number assigned to this computer: **Device 1** or **Device 3**. **Device 2** runs the companion macOS app.
2. Extract the complete archive to a writable folder. Keep its files together.
3. If this is a private device package produced by the Mac setup tool, `config.json` is already included. Otherwise run **Configure.cmd** and enter the device number, Device 2's LAN IPv4 address, and the pairing key supplied by the owner of that setup.
4. Quit the previous helper before upgrading. Run **Start.cmd**. Find the blue monitor icon in the notification area; Windows may place it under the hidden-icons arrow.
5. Right-click the icon for the menu. Press the physical keyboard buttons to test switching.

The keyboard and computer must be awake. Both computers must be on the same reachable LAN, and the monitor must have DDC/CI enabled. Device 2's macOS app must be running. Windows firewall or corporate policy can restrict LAN/HID access even when administrator privileges are otherwise unnecessary; this app does not change those policies.

## Tray menu

| Item | Behavior |
| --- | --- |
| Follow Easy-Switch | Start or stop the background helper. The checkmark reflects whether its process is running. |
| Launch at sign-in | Enable or disable startup for the current Windows account. The checkmark reflects the actual Startup shortcut. |
| Diagnostics → Open logs folder | Open the working folder containing diagnostic logs. |
| Diagnostics → Export diagnostics | Save a ZIP containing logs and basic runtime information. Pairing configuration and keys are excluded. |
| Quit MonitorSwitch | Close the tray app and stop the helper it launched. |

Enabling startup copies the app to `%LOCALAPPDATA%\MonitorSwitch\Device1` or `Device3` and creates a shortcut in the current user's Startup folder. It starts the tray app after sign-in, rather than a system service. Disabling startup removes that shortcut and leaves the current session running until you quit.

One tray process owns one background HID helper. A per-device mutex prevents duplicate helpers. If a previous diagnostic window is already running, close it before opening the tray app.

## Diagnostics

`diagnostic.log` records connection changes, receiver readiness, monitor identification and DDC results. `switch-events.log` records relevant Logitech ChangeHost service packets. Ordinary keyboard characters are not recorded.

For a visible diagnostic session, quit the tray app and run **Run-Diagnostic.cmd**. Close that window to stop it. **Stop-Helper.cmd** is a recovery tool for stopping this user's helper processes.

Diagnostic logs can contain local IP addresses and hardware identifiers. Review an exported archive before posting it publicly. Never share `config.json` or a private device ZIP: they contain pairing keys.

## Compatibility

The current release targets MX Keys Mini for Business (Bluetooth / Logi Bolt), an Apple Silicon companion, and MSI G274QPF with HDMI 1, USB-C and HDMI 2. The fast Bolt return uses a confirmed ChangeHost notification rather than guessing from a disconnect. Other keyboards, monitors, input codes and channel assignments require compatibility work; this release does not claim universal hardware support.

Requires Windows PowerShell 5.1, a writable per-user folder, and Full Language mode. The launcher sets `ExecutionPolicy Bypass` only for its own process; it does not edit system policy, request elevation or bypass enterprise restrictions.

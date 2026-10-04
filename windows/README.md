# MonitorSwitch for Windows

A tray app that follows the physical Logitech Easy-Switch buttons and switches a shared monitor. No account, subscription, Windows service or administrator privileges are required.

## Setup

1. In the macOS app, use **Setup devices…** to assign device numbers and inputs, then **Export Windows profiles…**. Transfer this computer's private JSON profile to Windows.
2. Extract the complete Windows archive to a writable folder. Keep its files together and quit any older helper before upgrading.
3. Run **MonitorSwitch.exe**. On first launch the setup form opens: click **Import profile…**, select your profile and click **Save**. An existing configured package starts directly.
4. Find the black-and-white monitor icon in the notification area, including the hidden-icons arrow. Right-click it for **Setup device…** and the other options.
5. Press the physical keyboard buttons to test switching. If you change the macOS setup, export and import fresh profiles.

The setup form includes system type, local device number, macOS coordinator number and LAN address, a masked pairing key, the coordinator monitor input, Windows monitor name and port. Select **Windows** for this computer. Configure **macOS** devices in the macOS app. Device numbers can be 1, 2 or 3, but must differ from the coordinator.

All computers must be awake and on the same reachable LAN. Enable DDC/CI on the monitor and keep the macOS app running. Corporate policies can restrict LAN/HID access; this app does not change them. Private profiles contain pairing keys: never publish them.

## Tray menu

| Item | Behavior |
| --- | --- |
| Follow Easy-Switch | Enable or pause the connection worker inside the app. |
| Setup device… | Import a private profile or edit this Windows device. Saving restarts the connection; an existing startup shortcut is refreshed. |
| Launch at sign-in | Enable or disable startup for the current Windows account. The checkmark reflects the actual Startup shortcut. |
| Diagnostics → Open logs folder | Open the per-user folder containing diagnostic logs. |
| Diagnostics → Export diagnostics | Save a ZIP containing logs and basic runtime information. Pairing configuration and keys are excluded. |
| Quit MonitorSwitch | Close the application and stop its connection worker. |

Enabling startup copies the app to `%LOCALAPPDATA%\MonitorSwitch\Native` and creates a shortcut in the current user's Startup folder. It starts the tray app after sign-in, rather than a system service. Disabling startup removes that shortcut and leaves the current session running until you quit.

A single C# application owns the tray, HID connection and DDC/network worker threads. It does not launch PowerShell or change execution policy. A per-user mutex prevents duplicate native instances. Quit the previous PowerShell version before upgrading. An older PowerShell startup shortcut is replaced only when you explicitly enable **Launch at sign-in** in the native app.

## Diagnostics

`diagnostic.log` records connection changes, receiver readiness, monitor identification and DDC results. `switch-events.log` records relevant Logitech ChangeHost service packets. Ordinary keyboard characters are not recorded.

Settings and logs are saved in `%LOCALAPPDATA%\MonitorSwitch\Native`. Use **Diagnostics → Export diagnostics…** to collect both logs while the app is running. A private `config.json` beside the executable is imported only on first launch; later changes use **Setup device… → Import profile…**.

Diagnostic logs can contain local IP addresses and hardware identifiers. Review an exported archive before posting it publicly. Never share `config.json` or a private device ZIP: they contain pairing keys.

## Compatibility

The current release targets MX Keys Mini for Business (Bluetooth / Logi Bolt), an Apple Silicon companion, and MSI G274QPF with HDMI 1, USB-C and HDMI 2. The fast Bolt return uses a confirmed ChangeHost notification rather than guessing from a disconnect. Monitor name and input codes are configurable. The fast Bolt path currently applies to Windows channel 3 → macOS channel 2; other mappings use confirmed connection events and can be slower. Other keyboards and monitors have not been validated. Mouse following is provided by Logitech, independently of MonitorSwitch.

Requires Windows with .NET Framework 4.8 and an interactive user session. The executable requests `asInvoker` and does not install a service or request elevation.

## Antivirus test build

Version **0.10.0-test1** replaces the PowerShell runtime with a compiled application. Kaspersky Endpoint Security reported `PDM:Trojan.Win32.Generic` against the previous `MonitorSwitch-Tray.ps1`. The cause and whether that was a false positive are not established. This unsigned test executable has not yet been validated with Kaspersky or the physical Windows devices. Keep antivirus enabled during testing; do not add exclusions or bypass organizational restrictions. If a warning occurs, quit the app and record the detection name, file path and diagnostic logs. Private profiles and configured archives must not be uploaded to scanning services.

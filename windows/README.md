# MonitorSwitch for Windows

A tray app that follows the physical Logitech Easy-Switch buttons and switches a shared monitor. No account, subscription, Windows service or administrator privileges are required.

## Setup

1. Configure the three device numbers and monitor inputs in the Mac app's **Setup devices…**.
2. On the Mac choose **Pair Windows device…**, select this Windows computer's number and copy the code.
3. Download **MonitorSwitch.exe**, quit the old helper and run the new executable. Paste the code and click **Connect**. The code expires in five minutes and is single-use. No other files are needed.
4. Right-click the icon near the clock (check the hidden-icons arrow) for **Launch at sign-in**, diagnostics or settings.
5. Test the physical Easy-Switch buttons with all computers awake.

The same executable supports either Windows number. Existing installations start with their saved settings; use **Connect to Mac…** to replace those settings with a new code. Reconnect after changing the Mac's address, device numbers or monitor inputs.

**Advanced settings…** retains manual setup and **Import profile…** for older private JSON profiles. An adjacent `config.json` is imported only on first launch, when no saved settings exist. Stored settings take precedence. Imported input maps are preserved on Save.

All computers must be awake and reachable on the same IPv4 LAN. Enable DDC/CI and keep the Mac app running. Pairing uses a temporary local TCP port; switching uses UDP (default 25347). Corporate policies may restrict these connections or HID access. The application does not change those policies.

Codes and private profiles authorize access: never publish them. The profile is encrypted and authenticated in transit. The saved Windows key is protected for the current Windows account; another process running as that account is outside this protection boundary.

## Tray menu

| Item | Behavior |
| --- | --- |
| Connect to Mac… | Replace settings using a fresh Mac pairing code. |
| Follow Easy-Switch | Enable or pause the connection worker inside the app. |
| Advanced settings… | Import a private profile or edit this Windows device. Saving restarts the connection; an existing startup shortcut is refreshed. |
| Launch at sign-in | Enable or disable startup for the current Windows account. The checkmark reflects the actual Startup shortcut. |
| Diagnostics → Open logs folder | Open the per-user folder containing diagnostic logs. |
| Diagnostics → Export diagnostics | Save a ZIP containing logs and basic runtime information. Pairing configuration and keys are excluded. |
| Quit MonitorSwitch | Close the application and stop its connection worker. |

Enabling startup copies the app to `%LOCALAPPDATA%\MonitorSwitch\Native` and creates a shortcut in the current user's Startup folder. It starts the tray app after sign-in, rather than a system service. Disabling startup removes that shortcut and leaves the current session running until you quit.

A single C# application owns the tray, HID connection and DDC/network worker threads. It does not launch PowerShell or change execution policy. A per-user mutex prevents duplicate native instances. Quit the previous PowerShell version before upgrading. An older PowerShell startup shortcut is replaced only when you explicitly enable **Launch at sign-in** in the native app.

## Diagnostics

`diagnostic.log` records connection changes, receiver readiness, monitor identification and DDC results. `switch-events.log` records relevant Logitech ChangeHost service packets. Ordinary keyboard characters are not recorded.

Settings and logs are saved in `%LOCALAPPDATA%\MonitorSwitch\Native`. Use **Diagnostics → Export diagnostics…** to collect both logs while the app is running. A private `config.json` beside the executable is imported only on first launch; later changes use **Advanced settings… → Import profile…**.

Diagnostic logs can contain local IP addresses and hardware identifiers. Review an exported archive before posting it publicly. Never share `config.json` or a private device ZIP: they contain pairing keys.

## Compatibility

The current release targets MX Keys Mini for Business (Bluetooth / Logi Bolt), an Apple Silicon companion, and MSI G274QPF with HDMI 1, USB-C and HDMI 2. The fast Bolt return uses a confirmed ChangeHost notification rather than guessing from a disconnect. Monitor name and input codes are configurable. The fast Bolt path currently applies to Windows channel 3 → macOS channel 2; other mappings use confirmed connection events and can be slower. Other keyboards and monitors have not been validated. Mouse following is provided by Logitech, independently of MonitorSwitch.

Requires Windows with .NET Framework 4.8 and an interactive user session. The executable requests `asInvoker` and does not install a service or request elevation.

## Antivirus test build

The current **0.11.0-test1** distribution is a compiled application without a PowerShell runtime. Kaspersky Endpoint Security reported `PDM:Trojan.Win32.Generic` against the previous `MonitorSwitch-Tray.ps1`. The cause and whether that was a false positive are not established. This unsigned test executable has not yet been validated with Kaspersky or the physical Windows devices. Keep antivirus enabled during testing; do not add exclusions or bypass organizational restrictions. If a warning occurs, quit the app and record the detection name, file path and diagnostic logs. Private profiles and configured archives must not be uploaded to scanning services.

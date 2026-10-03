<p align="center"><img src="assets/icon.png" width="112" alt="MonitorSwitch icon"></p>
<h1 align="center">MonitorSwitch</h1>
<p align="center">One keyboard. One display. Three devices.</p>

MonitorSwitch follows the **physical Logitech Easy-Switch buttons** and changes a shared monitor's input. A native macOS menu-bar app and small Windows tray companions coordinate over your local network. Free, local and open source: no subscription, account or cloud.

## How it works

| Easy-Switch button | Device | Default monitor input |
| --- | --- | --- |
| **1** | Device 1 · Windows companion | HDMI 1 · DDC code 17 |
| **2** | Device 2 · macOS menu-bar app | USB-C · DDC code 16 |
| **3** | Device 3 · Windows companion | HDMI 2 · DDC code 18 |

The keyboard's own Easy-Switch action controls the keyboard connection. MonitorSwitch follows that action; it does not re-pair devices or switch your mouse. If your mouse already follows the keyboard, it continues to do so independently.

Windows helpers identify the keyboard and announce confirmed device changes using authenticated UDP messages. Device 2 controls the monitor through `m1ddc`. A Windows helper can send the return-input DDC command over HDMI when the monitor no longer accepts commands on the inactive USB-C connection. A confirmed Bolt ChangeHost notification provides the fast return path on Device 3. A disconnect alone is never treated as a destination selection.

## Compatibility

This release targets the configuration it was developed with:

- An Apple Silicon Mac on **Easy-Switch channel 2**.
- Windows computers on **channels 1 and/or 3**.
- Logitech **MX Keys Mini for Business**, Bluetooth and Logi Bolt.
- **MSI G274QPF** with DDC/CI enabled, HDMI 1 / USB-C / HDMI 2.
- Computers awake and reachable on the same local IPv4 network.

Device names are editable. The macOS monitor UUID and the three DDC input codes are configurable. The Windows monitor identification and return-input code currently target the configuration above. Other Logitech models, monitors and channel arrangements need compatibility work; numbered device labels do not imply universal hardware support.

No administrator privileges are required for normal Windows operation or its per-user startup. Corporate PowerShell, HID or firewall policies may restrict operation; MonitorSwitch does not change or circumvent those policies. Allow local UDP traffic to Device 2 on port **25347** if your network policy permits it. Pairing messages have timestamp and replay checks, so keep the system clocks synchronized.

## Build the macOS app

Requires macOS 12 or later on Apple Silicon, Xcode Command Line Tools (Clang, Make, Swift and Python 3), and the included `m1ddc` source.

```sh
zsh build.sh
```

Output: `build/MonitorSwitch.app`. The build does **not** install configuration, change startup settings or replace pairing keys. Its built-in parser checks run during the build. The local app is ad-hoc signed, not notarized; this repository does not provide an Apple Developer-signed distribution.

## Pair your devices

1. Connect the monitor and enable DDC/CI in its on-screen menu.
2. Pair the keyboard's physical channels with Devices 1, 2 and 3 as shown above.
3. On Device 2, find the display UUID:

   ```sh
   build/MonitorSwitch.app/Contents/Resources/m1ddc display list
   ```

4. Generate a private setup for your actual LAN address and display UUID:

   ```sh
   python3 scripts/configure.py --mac-ip YOUR_LAN_IPV4 --display-uuid YOUR_DISPLAY_UUID --install
   ```

   This installs the current user's macOS pairing configuration and creates private `MonitorSwitch-Device1.zip` and `MonitorSwitch-Device3.zip` packages in `private/`. Each Windows device receives its own random key. Existing pairing configuration is never overwritten.

5. Transfer each private ZIP directly to its matching Windows device, extract it, and run **Start.cmd**. It shows a notification-area icon, including under Windows' hidden-icons arrow. See the [Windows README](windows/README.md).
6. Open the macOS app. Grant **Input Monitoring** to that exact app bundle in System Settings → Privacy & Security if requested. Restart it after changing the permission. macOS may require authentication for granting Input Monitoring; this differs from Windows' no-admin setup.
7. Use **Devices & inputs…** to check your monitor UUID and input mapping. Test the physical buttons with all participating computers awake.

Private ZIP files and `config.json` contain pairing keys. They belong only to their owner; do not upload them to GitHub. The generic public Windows archive contains no private configuration.

## macOS menu

- **Device 1 / Device 2 / Device 3** — manually request the associated input.
- **Follow Easy-Switch** — enable or pause automatic following.
- **Devices & inputs…** — edit names, monitor UUID and input mapping.
- **Diagnostics → Observe only** — log automatic events without switching the display.
- **Diagnostics → Read current input** — request the current DDC input value.
- **Diagnostics → Open logs folder** — open `~/Library/Logs/MonitorSwitch`.
- **Quit MonitorSwitch** — stop the app and its local relay.

The device checkmark represents the last requested channel. A successful DDC write is reported as a command sent; it does not prove which picture is visible after the inactive connection stops responding.

For macOS login startup, add the same app bundle to System Settings → General → Login Items. Keep the installed app at a stable path. A rebuild changes an ad-hoc signature and may require re-enabling Input Monitoring.

## Windows tray menu

- **Follow Easy-Switch** — start or stop the helper, with a running-process checkmark.
- **Launch at sign-in** — enable or disable current-user startup; the checkmark reflects the Startup shortcut.
- **Diagnostics** — open logs or export a diagnostic ZIP without configuration or pairing keys.
- **Quit MonitorSwitch** — stop the tray app and its child helper.

This is a user-session application, not a Windows service. It starts after sign-in when enabled. No scheduled task, registry startup entry or elevated installer is used. A per-device mutex prevents duplicate helpers. Tray, helper and startup management are written in Windows PowerShell 5.1 using .NET / WinForms and native Windows APIs; no additional runtime is installed.

## Troubleshooting

**No tray icon:** check the hidden-icons arrow. Extract the full package and ensure `config.json` exists. Quit an older helper before upgrading. If needed, use `Run-Diagnostic.cmd` after quitting the tray app.

**Device 2 does not return:** keep both apps running and the computers awake. Check the Windows diagnostic log for receiver readiness and confirmed keyboard identity. Bluetooth reconnection can take longer than the confirmed Bolt event path.

**Display returns to another source:** automatic input detection in the monitor can override a source without a live video signal. Test with the destination computer awake and producing a signal.

**Permission changed after a rebuild:** re-enable Input Monitoring for the same macOS bundle and restart. Ad-hoc signing cannot guarantee a stable macOS permission identity across builds.

**DDC writes fail:** check DDC/CI, the selected display UUID and input codes. Some docks, cables and inactive monitor inputs do not carry DDC commands. This release's Windows identification intentionally avoids changing unrelated displays.

**Diagnostics:** macOS logs live in `~/Library/Logs/MonitorSwitch`; Windows logs live beside the running helper. Logs record service messages and hardware/network diagnostics, not typed text. They may contain local addresses and device identifiers: review before sharing. Never share pairing files.

## Development and release packaging

```sh
python3 -m unittest discover -s tests
python3 -m py_compile network_follow.py scripts/configure.py
python3 scripts/package.py
```

The public Windows ZIP is created in `build/release/`. The macOS app can be archived after building; paired configurations, historical experimental builds and diagnostics are excluded from public artifacts.

## License and credits

MonitorSwitch code is MIT licensed. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

- [m1ddc](https://github.com/waydabber/m1ddc) by waydabber — included macOS DDC/CI implementation, MIT.
- [mxswitch](https://github.com/marcocosta97/mxswitch) by Marco Costa — Windows native HID enumeration adapted under MIT; its notice is retained in the helper.
- [SwiGi](https://github.com/LeeHoffka/SwiGi) and [OpenLogi HID++ ChangeHost documentation](https://openlogi.org/hidpp/features/x1814-change-host) — protocol references.

MonitorSwitch is an independent project and is not affiliated with Logitech, MSI or Apple.

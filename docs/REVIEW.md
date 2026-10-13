# Implementation review — 0.11.0-test1

MonitorSwitch is useful for its tested Logitech/MSI setup, but remains an experimental hardware integration. The following is a source review with automated checks, not a certification or universal compatibility claim.

## Corrected in this version

- Windows setup now retains imported monitor input mappings for every coordinator channel (first fixed in test3).
- Windows target-input messages use structured JSON validation with exact fields and types instead of regular-expression extraction. Authenticated input codes must match the configured target; timestamps, session episodes and replay IDs are checked.
- Retired relay episodes expire rather than accumulating for the entire app session. Late packets from a retired episode cannot replace the current peer/session used to send commands.
- Saved Windows pairing keys use DPAPI for the current account, with plaintext legacy profile import retained.
- Pairing is on demand, bounded in lifetime and response size, authenticated and encrypted. Old helper callbacks cannot update a replacement pairing session.
- Public Windows distribution is one executable; diagnostics and startup are accessible in the tray. Source, scripts and private profiles are separate from the normal download.

## Remaining issues and limits

| Area | Current limitation / impact |
| --- | --- |
| Signing and endpoint protection | Windows binaries are unsigned. The previous PowerShell helper triggered Kaspersky behavior detection; replacing it with C# does not prove antivirus acceptance. macOS is ad-hoc signed, not notarized; rebuilding can require Input Monitoring reauthorization. |
| Mac dependencies | The bundle includes a Python relay and pairing helper but invokes `/usr/bin/python3`. A clean Mac needs Apple Command Line Tools. Moving the bundle alone is not a dependency-free installation. |
| Hardware coverage | Physical evidence is limited to MX Keys Mini for Business, MX Master 3S following through Logitech, and MSI G274QPF. Other keyboards, monitor input codes, docks and multiple displays need testing. |
| Fast return path | Exact Bolt ChangeHost fast detection remains gated to the original Windows 3 → Mac 2 arrangement. Other mappings use confirmed keyboard connection events; Bluetooth reconnection adds latency. A disconnect alone cannot identify the target safely. |
| Coordinator | One Mac must remain awake and reachable. A Windows-only setup and multiple coordinators are unsupported. Windows-to-Windows routing still passes through the Mac. |
| Network | Fixed IPv4 address, no discovery or DHCP tracking. Address changes require reconfiguration and pairing again. Corporate firewall/HID/application rules can prevent operation. |
| DDC | A successful write means the command was sent, not that the intended image is visible. Inactive connections or docks may reject DDC. Blocking driver calls do not have a reliable application-level hard cancellation. |
| Logging | Logs currently have no automatic rotation and can grow over time. Exported diagnostics can contain IP addresses and hardware identifiers; review before sharing. Typed text is not recorded. |
| Security boundary | Pairing is custom and has no independent audit. Full codes are bearer credentials; clipboard retention and same-user compromise remain risks. Mac config and exported profiles contain plaintext keys. |
| Packaging debt | Legacy PowerShell sources remain in the repository for provenance/backward compatibility. The new public executable package does not run or include them. |

## Validation and next checks

CI builds the actual Windows application and checks setup preservation, DPAPI persistence, icon/UI creation, authenticated DDC message parsing, replay rejection and cross-platform pairing decryption. Python tests exercise the real relay loop and the Mac HTTP/crypto implementation. Mac compilation includes parser checks.

Still required on physical machines: new first-run pairing on Device 1 and Device 2; transitions in all directions with the Mac on channel 3; restart/sign-in startup; suspend/resume; DHCP/address changes; long-run diagnostics; endpoint-protection acceptance through the organization's normal review process. CI does not validate those outcomes.

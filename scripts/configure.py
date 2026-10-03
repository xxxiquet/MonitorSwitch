#!/usr/bin/env python3
"""Create private pairing files and numbered Windows packages. Never publish them."""
import argparse
import ipaddress
import json
import pathlib
import secrets
import shutil
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS_FILES = ('Configuration-UI.ps1', 'Start.cmd', 'Configure.cmd', 'Configure.ps1', 'MonitorSwitch-Tray.ps1',
                 'MonitorSwitch-Windows.ps1', 'Setup-Autostart.ps1',
                 'Export-Diagnostics.ps1', 'Run-Diagnostic.cmd', 'README.md',
                 'Enable-Autostart.cmd', 'Disable-Autostart.cmd', 'Stop-Helper.cmd', 'Stop-Helper.ps1')

def package(output, channel=None, config=None):
    prefix = f'MonitorSwitch-Device{channel}' if channel else 'MonitorSwitch-Windows'
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in WINDOWS_FILES:
            archive.write(ROOT / 'windows' / name, f'{prefix}/{name}')
        for notice in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            archive.write(ROOT / notice, f'{prefix}/{notice}')
        if config:
            archive.writestr(f'{prefix}/config.json', json.dumps(config, indent=2) + '\n')
    output.chmod(0o600 if config else 0o644)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mac-ip', required=True, help='Device 2 LAN IPv4 address')
    parser.add_argument('--display-uuid', required=True, help='UUID from m1ddc display list')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT/'private')
    parser.add_argument('--install', action='store_true', help='Install pairing config for the current macOS user')
    args = parser.parse_args()
    if ipaddress.ip_address(args.mac_ip).version != 4:
        parser.error('Use a LAN IPv4 address')
    output=args.output.expanduser().resolve()
    config_path=output/'network-config.json'
    destination=pathlib.Path.home()/'Library/Application Support/MonitorSwitch/network-config.json'
    if config_path.exists() or (args.install and destination.exists()):
        parser.error('Existing pairing configuration found. Choose another output directory; existing keys are never overwritten.')
    output.mkdir(parents=True,exist_ok=True);output.chmod(0o700)
    keys={str(channel):secrets.token_hex(32) for channel in (1,3)}
    config={'macIP':args.mac_ip,'port':25347,'displayUUID':args.display_uuid,'keys':keys}
    config_path.write_text(json.dumps(config,indent=2)+'\n');config_path.chmod(0o600)
    for channel in (1,3):
        helper={'channel':channel,'macIP':args.mac_ip,'port':25347,'key':keys[str(channel)]}
        package(output/f'MonitorSwitch-Device{channel}.zip',channel,helper)
    if args.install:
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(config_path,destination);destination.chmod(0o600)
    print(f'Private device packages saved to {output}. Transfer each ZIP to its matching device. Do not publish this directory.')

if __name__=='__main__':main()

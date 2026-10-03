"""Authenticated local Easy-Switch relay. Diagnostic mode is the default.

HP helpers confirm keyboard identity and their configured active host slot.
Mac channel 2 is confirmed by the existing MonitorSwitch HID++ log.
No keyboard characters, network scans, startup services or remote commands.
"""
import argparse
import hashlib
import hmac
import json
import pathlib
import socket
import subprocess
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent
LOG = pathlib.Path.home() / 'Library/Logs/MonitorSwitch/network.log'
KEYBOARD_LOG = pathlib.Path.home() / 'Library/Logs/MonitorSwitch/monitor.log'
DDC = ROOT / 'build/MonitorSwitch.app/Contents/Resources/m1ddc'
INPUTS = {1: 17, 2: 16, 3: 18}


def decode_packet(raw, keys, now, seen):
    if len(raw) > 1024:
        return None
    try:
        p = json.loads(raw)
        if not isinstance(p, dict):
            return None
        ready = p.get('v') == 2
        fields = {'v', 'channel', 'id', 'time', 'episode', 'mac'} if ready else {'v', 'channel', 'active', 'id', 'time', 'episode', 'mac'}
        if set(p) != fields:
            return None
        if p['v'] not in (1, 2) or type(p['channel']) is not int or p['channel'] not in keys:
            return None
        if not ready and (type(p['active']) is not int or p['active'] not in (0, 1)):
            return None
        if type(p['time']) is not int or abs(now - p['time']) > 120:
            return None
        if not isinstance(p['id'], str) or len(p['id']) != 32 or p['id'] in seen:
            return None
        int(p['id'], 16)
        if not isinstance(p['episode'], str) or len(p['episode']) != 32:
            return None
        int(p['episode'], 16)
        text = f"ready|2|{p['channel']}|{p['id']}|{p['time']}|{p['episode']}" if ready else f"1|{p['channel']}|{p['active']}|{p['id']}|{p['time']}|{p['episode']}"
        expected = hmac.new(keys[p['channel']], text.encode(), hashlib.sha256).hexdigest()
        if not isinstance(p['mac'], str) or not hmac.compare_digest(expected, p['mac']):
            return None
        seen[p['id']] = now
        return p
    except (KeyError, ValueError, TypeError, UnicodeError):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=pathlib.Path, default=ROOT / 'network-config.json')
    parser.add_argument('--return-input', type=int, default=16)
    parser.add_argument('--live', action='store_true')
    parser.add_argument('--emit-events', action='store_true', help='Send authenticated channel events to the parent Mac app; never run DDC here')
    args = parser.parse_args()
    if args.live and args.emit_events:
        parser.error('--live and --emit-events cannot be combined')
    config = json.loads(args.config.read_text())
    return_input = args.return_input
    if not 1 <= return_input <= 255:
        parser.error('--return-input must be between 1 and 255')
    mac_channel = config.get('macChannel', 2)
    if type(mac_channel) is not int or mac_channel not in (1, 2, 3):
        parser.error('macChannel must be 1, 2 or 3')
    display_uuid = config.get('displayUUID', '')
    keys = {int(k): bytes.fromhex(v) for k, v in config['keys'].items()}
    if mac_channel in keys or any(ch not in (1, 2, 3) for ch in keys):
        parser.error('Pairing keys must belong to remote channels')
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((config['macIP'], config['port']))
    sock.settimeout(0.02)
    LOG.parent.mkdir(parents=True, exist_ok=True)

    def log(text):
        line = time.strftime('%Y-%m-%d %H:%M:%S') + ' ' + text
        print(line, flush=True)
        with LOG.open('a') as f:
            f.write(line + '\n')

    seen, states, retired = {}, {ch: None for ch in keys}, set()
    peers = {}
    last_episodes = {}
    last_channel = mac_channel
    ready_hosts = {}
    mac_connected = False
    for line in KEYBOARD_LOG.read_text().splitlines()[-500:]:
        if 'Easy-Switch enabled ·' in line or 'HID: keyboard disconnected' in line or 'Keyboard service access denied' in line:
            mac_connected = False
        elif f'Keyboard on channel {mac_channel} ·' in line:
            mac_connected = True

    def return_to_mac(host):
        episode = last_episodes.get(host)
        if not args.emit_events or not episode or host not in peers:
            return
        request = {'v': 1, 'input': return_input, 'id': __import__('uuid').uuid4().hex,
                   'time': int(time.time()), 'episode': episode}
        canonical = f"input|1|{return_input}|{request['id']}|{request['time']}|{episode}"
        request['mac'] = hmac.new(keys[host], canonical.encode(), hashlib.sha256).hexdigest()
        encoded = json.dumps(request).encode()
        for _ in range(3):
            sock.sendto(encoded, peers[host])
        log(f'Request coordinator input through active device channel {host}')
    mode = 'APP EVENTS: DDC managed by MonitorSwitch' if args.emit_events else ('LIVE' if args.live else 'TEST: monitor unchanged')
    log(f"Listening on port {config['port']}; {mode}")
    with KEYBOARD_LOG.open() as keyboard:
        keyboard.seek(0, 2)
        try:
            while True:
                channel = None
                try:
                    raw, peer = sock.recvfrom(1025)
                    packet = decode_packet(raw, keys, time.time(), seen)
                    if packet:
                        ch, active = packet['channel'], bool(packet.get('active', 0))
                        peers[ch] = peer
                        episode = packet['episode']
                        if packet['v'] == 2:
                            changed = ready_hosts.get(ch) != episode
                            ready_hosts[ch] = episode
                            last_episodes[ch] = episode
                            if changed:
                                log(f'Windows helper ready before keyboard connection: channel={ch}')
                                if mac_connected:
                                    return_to_mac(ch)
                            continue
                        if active:
                            last_episodes[ch] = episode
                        if episode in retired:
                            continue
                        if (active and states[ch] != episode) or (not active and states[ch] == episode):
                            states[ch] = episode if active else None
                            log(f"Device {ch} ({peer[0]}): keyboard {'connected' if active else 'disconnected'}; channel={ch}")
                            if active:
                                channel = ch
                except socket.timeout:
                    pass
                for line in keyboard.readlines():
                    if 'HID: keyboard disconnected' in line or 'Keyboard service access denied' in line:
                        mac_connected = False
                    if f'Keyboard on channel {mac_channel} ·' in line or f'TEST: channel={mac_channel} input={return_input}' in line:
                        channel = mac_channel
                        mac_connected = True
                        log(f'Mac: keyboard confirmed on channel {mac_channel}')
                if channel == mac_channel and last_channel == mac_channel:
                    for host in ready_hosts:
                        return_to_mac(host)
                if channel is not None and channel != last_channel:
                    # A positively identified new host retires the previous
                    # connection episode. Late/lost UDP disconnects cannot
                    # make an old heartbeat pull the monitor back.
                    if channel == mac_channel and args.emit_events:
                        hosts = (last_channel,) if last_channel in keys else tuple(ready_hosts)
                        for host in hosts:
                            return_to_mac(host)
                    for ch in states:
                        if ch != channel and states[ch] is not None:
                            retired.add(states[ch])
                            states[ch] = None
                    last_channel = channel
                    if args.emit_events:
                        if channel in keys:
                            print(f'MONITORSWITCH_CHANNEL:{channel}', flush=True)
                    elif args.live:
                        try:
                            result = subprocess.run([str(DDC), 'display', display_uuid, 'set', 'input', str(INPUTS[channel])], capture_output=True, text=True, timeout=5)
                            log(f"channel={channel} input={INPUTS[channel]}: {'command sent' if result.returncode == 0 else 'DDC error'}")
                        except (OSError, subprocess.TimeoutExpired) as e:
                            log(f'DDC failed: {e}')
                    else:
                        log(f'TEST: channel={channel} input={INPUTS[channel]}, monitor unchanged')
                if len(seen) > 256:
                    seen = {k: t for k, t in seen.items() if time.time() - t < 120}
        finally:
            sock.close()


if __name__ == '__main__':
    main()

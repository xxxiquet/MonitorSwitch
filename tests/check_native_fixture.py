"""Validate packets produced by the actual Windows executable against the Mac relay."""
import importlib.util
import json
from pathlib import Path
import sys
import time
spec = importlib.util.spec_from_file_location('relay', Path(__file__).resolve().parents[1]/'network_follow.py')
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
fixture = json.loads(Path(sys.argv[1]).read_text())
keys = {3: bytes.fromhex(fixture['key'])}
seen = {}
for raw, expected in zip(fixture['packets'], (None, 1, 0)):
    packet = relay.decode_packet(raw.encode(), keys, int(time.time()), seen)
    assert packet is not None and packet.get('active') == expected
    assert relay.decode_packet(raw.encode(), keys, int(time.time()), seen) is None
print('Native Windows packets accepted by the Mac relay; replays rejected.')

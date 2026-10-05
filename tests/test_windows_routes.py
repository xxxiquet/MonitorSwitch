"""Exercise the real relay loop with simulated Windows peers; no HID/DDC calls."""
import hashlib
import hmac
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]

class WindowsRoutesIntegration(unittest.TestCase):
    def test_one_to_three_and_back_uses_source_peer(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            reserve = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]; reserve.close()
            config = {'macIP':'127.0.0.1','port':port,'macChannel':2,
                      'inputs':[77,16,88], 'keys':{'1':'aa'*32,'3':'bb'*32}}
            (tmp/'config.json').write_text(json.dumps(config)); (tmp/'keyboard.log').write_text('')
            code = "import sys,pathlib;sys.path.insert(0,sys.argv[1]);import network_follow as m;m.LOG=pathlib.Path(sys.argv[2]);m.KEYBOARD_LOG=pathlib.Path(sys.argv[3]);sys.argv=['relay','--config',sys.argv[4],'--emit-events'];m.main()"
            process = subprocess.Popen([sys.executable,'-u','-c',code,str(ROOT),str(tmp/'relay.log'),str(tmp/'keyboard.log'),str(tmp/'config.json')],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            peers = {ch:socket.socket(socket.AF_INET,socket.SOCK_DGRAM) for ch in (1,3)}
            for sock in peers.values():sock.bind(('127.0.0.1',0));sock.settimeout(0.1)
            episodes = {1:'11'*16,3:'33'*16}
            counter = 0
            def event(ch,ready):
                nonlocal counter
                counter += 1
                packet={'v':2 if ready else 1,'channel':ch,'id':f'{counter:032x}', 'time':int(time.time()),'episode':episodes[ch]}
                if not ready:packet['active']=1
                canonical=f"ready|2|{ch}|{packet['id']}|{packet['time']}|{episodes[ch]}" if ready else f"1|{ch}|1|{packet['id']}|{packet['time']}|{episodes[ch]}"
                packet['mac']=hmac.new(bytes.fromhex(config['keys'][str(ch)]),canonical.encode(),hashlib.sha256).hexdigest()
                peers[ch].sendto(json.dumps(packet).encode(),('127.0.0.1',port))
            def request(source,target,input_code):
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    try:packet=json.loads(peers[source].recv(2048))
                    except socket.timeout:continue
                    if packet.get('v')!=3 or packet.get('target')!=target:continue
                    self.assertEqual(packet['input'],input_code)
                    self.assertEqual(packet['episode'],episodes[source])
                    canonical=f"input|3|{target}|{input_code}|{packet['id']}|{packet['time']}|{episodes[source]}"
                    expected=hmac.new(bytes.fromhex(config['keys'][str(source)]),canonical.encode(),hashlib.sha256).hexdigest()
                    self.assertEqual(packet['mac'],expected)
                    return
                self.fail(f'No authenticated input {input_code} through source {source}')
            try:
                deadline=time.monotonic()+5
                while not (tmp/'relay.log').exists() and time.monotonic()<deadline:
                    if process.poll() is not None:self.fail(process.communicate()[1].decode())
                    time.sleep(0.02)
                self.assertTrue((tmp/'relay.log').exists())
                event(1,True);event(3,True);event(1,False)
                request(1,1,77)
                event(3,False);request(1,3,88)
                episodes[1]='22'*16
                event(1,False);request(3,1,77)
            finally:
                process.terminate();process.communicate(timeout=5)
                for sock in peers.values():sock.close()

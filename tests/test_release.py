import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT=Path(__file__).resolve().parents[1]
def module(path):
    spec=importlib.util.spec_from_file_location(path.stem,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
relay=module(ROOT/'network_follow.py')
setup=module(ROOT/'scripts/configure.py')

class AuthenticatedEvents(unittest.TestCase):
    def setUp(self):
        self.keys={1:bytes.fromhex('ab'*32),3:bytes.fromhex('cd'*32)}
        self.event={'v':1,'channel':3,'active':1,'id':'01'*16,'time':1000,'episode':'02'*16}
    def signed(self,event):
        p=dict(event)
        canonical=f"ready|2|{p['channel']}|{p['id']}|{p['time']}|{p['episode']}" if p['v']==2 else f"1|{p['channel']}|{p['active']}|{p['id']}|{p['time']}|{p['episode']}"
        p['mac']=hmac.new(self.keys[p['channel']],canonical.encode(),hashlib.sha256).hexdigest()
        return json.dumps(p).encode()
    def test_valid_connection_and_replay(self):
        seen={};raw=self.signed(self.event)
        self.assertEqual(relay.decode_packet(raw,self.keys,1000,seen)['channel'],3)
        self.assertIsNone(relay.decode_packet(raw,self.keys,1000,seen))
    def test_remote_channel_two_with_coordinator_on_one(self):
        self.keys={2:bytes.fromhex('ab'*32),3:bytes.fromhex('cd'*32)}
        event=dict(self.event,channel=2)
        self.assertEqual(relay.decode_packet(self.signed(event),self.keys,1000,{})['channel'],2)
        packet=json.loads(self.signed(event));packet['channel']=1
        self.assertIsNone(relay.decode_packet(json.dumps(packet).encode(),self.keys,1000,{}))
    def test_startup_readiness_without_keyboard(self):
        event=dict(self.event,v=2);event.pop('active')
        self.assertEqual(relay.decode_packet(self.signed(event),self.keys,1000,{})['v'],2)
    def test_tampered_channel_rejected(self):
        event=json.loads(self.signed(self.event));event['channel']=1
        self.assertIsNone(relay.decode_packet(json.dumps(event).encode(),self.keys,1000,{}))
    def test_stale_packet_rejected(self):
        self.assertIsNone(relay.decode_packet(self.signed(self.event),self.keys,1121,{}))
    def test_boolean_active_is_not_integer(self):
        event=dict(self.event,active=True)
        self.assertIsNone(relay.decode_packet(self.signed(event),self.keys,1000,{}))
    def test_malformed_and_oversized(self):
        for raw in [b'not json',b'[]',b'{}',b'x'*1025]:
            self.assertIsNone(relay.decode_packet(raw,self.keys,1000,{}))

class ReleaseContents(unittest.TestCase):
    def test_public_package_contains_tray_and_docs_but_no_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'public.zip';exe=Path(tmp)/'fixture.exe';exe.write_bytes(b'MZ-package-test-fixture');setup.package(path,executable=exe)
            with zipfile.ZipFile(path) as archive:
                names=archive.namelist()
                self.assertTrue(any(n.endswith('/MonitorSwitch.exe') for n in names))
                self.assertTrue(any(n.endswith('/README.md') for n in names))
                self.assertFalse(any(n.endswith(('.ps1','.cmd','.vbs')) for n in names))
                self.assertFalse(any(n.endswith(('.log','config.json')) for n in names))
    def test_private_packages_use_the_given_device_key_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'device.zip';config={'channel':1,'key':'11'*32}
            exe=Path(tmp)/'fixture.exe';exe.write_bytes(b'MZ-package-test-fixture')
            setup.package(path,1,config,executable=exe)
            with zipfile.ZipFile(path) as archive:
                self.assertEqual(json.loads(archive.read('MonitorSwitch-Device1/config.json')),config)

if __name__=='__main__':unittest.main()

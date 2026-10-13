import base64
import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import sys
import threading
import unittest
import urllib.error
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('pairing',ROOT/'pairing_server.py')
pairing=importlib.util.module_from_spec(spec);spec.loader.exec_module(pairing)

class PairingCodes(unittest.TestCase):
    def test_code_roundtrip_and_entropy(self):
        secret=bytes(range(16));code=pairing.code_for('192.0.2.1',30000,2,secret)
        self.assertEqual(len(code),35)
        data=base64.urlsafe_b64decode(code[4:]+'=')
        self.assertEqual(data[7:],secret);self.assertEqual(data[6],2)
        self.assertEqual(int.from_bytes(data[4:6],'big'),30000)
    def test_domains_are_separate(self):
        secret=bytes(range(16))
        self.assertNotEqual(pairing.derive(secret,pairing.ENC_LABEL),pairing.derive(secret,pairing.AUTH_LABEL))

@unittest.skipUnless(sys.platform=='darwin','Uses the macOS CommonCrypto backend')
class PairingTransfer(unittest.TestCase):
    def setUp(self):
        self.secret=bytes(range(16));self.profile={'deviceType':'Windows','channel':2,'macChannel':3,'macIP':'127.0.0.1','key':'ab'*32,'inputs':[17,18,16],'returnInput':16}
    def request(self,server,proof=None):
        nonce='a'*32
        body={'v':1,'nonce':nonce,'mac':proof or hmac.new(self.secret,('request|1|'+nonce).encode(),hashlib.sha256).hexdigest()}
        req=urllib.request.Request(f'http://127.0.0.1:{server.server_port}/pair',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        worker=threading.Thread(target=server.handle_request);worker.start()
        try:
            with opener.open(req,timeout=3) as response:return json.load(response)
        finally:worker.join(timeout=3)
    def test_authenticated_encrypted_single_use(self):
        with pairing.make_server(self.profile,self.secret) as server:
            result=self.request(server)
            self.assertNotIn(self.profile['key'],json.dumps(result))
            canonical=f"response|1|{result['nonce']}|{result['iv']}|{result['ciphertext']}"
            self.assertEqual(result['mac'],hmac.new(pairing.derive(self.secret,pairing.AUTH_LABEL),canonical.encode(),hashlib.sha256).hexdigest())
            clear=pairing.crypt(base64.b64decode(result['ciphertext']),pairing.derive(self.secret,pairing.ENC_LABEL),base64.b64decode(result['iv']),True)
            self.assertEqual(json.loads(clear),self.profile)
            with self.assertRaises(urllib.error.HTTPError) as failure:self.request(server)
            self.assertEqual(failure.exception.code,410)
    def test_unauthenticated_request_does_not_consume_code(self):
        with pairing.make_server(self.profile,self.secret) as server:
            with self.assertRaises(urllib.error.HTTPError):self.request(server,'0'*64)
            self.assertFalse(server.used)
            self.assertEqual(self.request(server)['v'],1)
    def test_expired_code_rejected(self):
        with pairing.make_server(self.profile,self.secret,ttl=-1) as server:
            with self.assertRaises(urllib.error.HTTPError) as failure:self.request(server)
            self.assertEqual(failure.exception.code,410)

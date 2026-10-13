"""On-demand, five-minute, one-use encrypted Windows profile transfer.

Secrets arrive through stdin, never process arguments, URLs or logs.
AES-CBC/PKCS7 is provided by Apple's CommonCrypto; HMAC-SHA256 authenticates
requests and the ciphertext before Windows decrypts it. The code is a bearer
secret with 128 random bits, not a guessable numeric PIN.
"""
import base64
import ctypes
import hashlib
import hmac
import ipaddress
import json
import secrets
import socket
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ENC_LABEL = b'MonitorSwitch pairing encryption v1'
AUTH_LABEL = b'MonitorSwitch pairing authentication v1'


def derive(secret, label):
    return hmac.new(secret, label, hashlib.sha256).digest()


def crypt(data, key, iv, decrypt=False):
    if sys.platform != 'darwin':
        raise RuntimeError('Pairing encryption requires macOS CommonCrypto')
    library = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib')
    call = library.CCCrypt
    call.argtypes = [ctypes.c_uint,ctypes.c_uint,ctypes.c_uint,ctypes.c_void_p,ctypes.c_size_t,
                     ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,
                     ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t)]
    call.restype = ctypes.c_int
    output = ctypes.create_string_buffer(len(data)+16)
    moved = ctypes.c_size_t()
    status = call(1 if decrypt else 0,0,1,key,len(key),iv,data,len(data),output,len(output),ctypes.byref(moved))
    if status != 0:
        raise ValueError('Encryption failed')
    return output.raw[:moved.value]


def code_for(ip, port, channel, secret):
    if len(secret)!=16 or channel not in (1,2,3) or not 1<=port<=65535:
        raise ValueError('Invalid pairing parameters')
    raw=ipaddress.IPv4Address(ip).packed+struct.pack('!HB',port,channel)+secret
    return 'MS1-'+base64.urlsafe_b64encode(raw).decode().rstrip('=')


def envelope(profile, secret, nonce):
    iv=secrets.token_bytes(16)
    plaintext=json.dumps(profile,separators=(',',':')).encode()
    ciphertext=crypt(plaintext,derive(secret,ENC_LABEL),iv)
    result={'v':1,'nonce':nonce,'iv':base64.b64encode(iv).decode(),'ciphertext':base64.b64encode(ciphertext).decode()}
    canonical=f"response|1|{nonce}|{result['iv']}|{result['ciphertext']}"
    result['mac']=hmac.new(derive(secret,AUTH_LABEL),canonical.encode(),hashlib.sha256).hexdigest()
    return result


def make_server(profile, secret, ttl=300):
    deadline=time.monotonic()+ttl
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def setup(self):
            super().setup();self.connection.settimeout(2)
        def do_POST(self):
            try:
                if self.path!='/pair' or self.server.used or time.monotonic()>=deadline:
                    self.send_error(410);return
                length=int(self.headers.get('Content-Length','0'))
                if not 1<=length<=1024:raise ValueError()
                request=json.loads(self.rfile.read(length))
                if not isinstance(request,dict) or set(request)!={'v','nonce','mac'} or type(request['v']) is not int or request['v']!=1:raise ValueError()
                nonce=request['nonce'];proof=request['mac']
                if not isinstance(nonce,str) or len(nonce)!=32 or any(c not in '0123456789abcdef' for c in nonce):raise ValueError()
                expected=hmac.new(secret,f'request|1|{nonce}'.encode(),hashlib.sha256).hexdigest()
                if not isinstance(proof,str) or not hmac.compare_digest(expected,proof):raise ValueError()
                body=json.dumps(envelope(profile,secret,nonce)).encode()
                self.server.used=True  # consume before transmission; retries need a fresh code
                self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store')
                self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);self.wfile.flush()
            except (ValueError,KeyError,TypeError,UnicodeError):self.send_error(400)
            except (BrokenPipeError,ConnectionResetError,socket.timeout):pass
    server=HTTPServer((profile['macIP'],0),Handler)
    server.used=False;server.deadline=deadline;server.timeout=0.5
    return server


def main():
    try:
        raw=sys.stdin.buffer.readline(16385)
        if len(raw)>16384:raise ValueError()
        settings=json.loads(raw);profile=settings['profile'];secret=bytes.fromhex(settings['secret'])
        if len(secret)!=16 or profile['channel']==profile['macChannel'] or profile['channel'] not in (1,2,3):raise ValueError()
        # Check the native crypto backend before exposing a code.
        crypt(b'test',derive(secret,ENC_LABEL),b'\0'*16)
        with make_server(profile,secret) as server:
            print(json.dumps({'code':code_for(profile['macIP'],server.server_port,profile['channel'],secret)}),flush=True)
            while not server.used and time.monotonic()<server.deadline:server.handle_request()
            print(json.dumps({'status':'paired' if server.used else 'expired'}),flush=True)
    except Exception:
        print(json.dumps({'status':'unavailable'}),flush=True);return 1
    return 0

if __name__=='__main__':sys.exit(main())

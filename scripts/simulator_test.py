import subprocess, json, time, os, pathlib, urllib.request, urllib.error, hashlib, http.server, threading

def run(*args):
    return subprocess.check_output(args, text=True).strip()

devices = json.loads(run('xcrun','simctl','list','devices','available','--json'))
phone = next(d for items in devices['devices'].values() for d in items if 'iPhone' in d['name'])
udid = phone['udid']
subprocess.run(['xcrun','simctl','boot',udid], check=False)
run('xcrun','simctl','bootstatus',udid,'-b')
assert pathlib.Path('build/sim/Build/Products/Debug-iphonesimulator/Hop.app/hop/index.html').is_file(), 'Renderer not bundled'
run('xcrun','simctl','install',udid,'build/sim/Build/Products/Debug-iphonesimulator/Hop.app')
outgoing=[]
class Receiver(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"accepted":true,"token":"ci-token"}')
    def do_PUT(self):
        assert self.headers.get('x-hop-token')=='ci-token'
        outgoing.append(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        self.send_response(200);self.end_headers();self.wfile.write(b'{"ok":true}')
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Receiver)
threading.Thread(target=server.serve_forever,daemon=True).start()
env = dict(os.environ, SIMCTL_CHILD_HOP_PROTOCOL_TEST='1',SIMCTL_CHILD_HOP_TEST_RECEIVER_PORT=str(server.server_port))
subprocess.run(['xcrun','simctl','launch',udid,'app.hop.ios'],env=env,check=True)
container = pathlib.Path(run('xcrun','simctl','get_app_container',udid,'app.hop.ios','data'))
ready = container/'Documents/.hop-ready.json'
for _ in range(120):
    if ready.exists(): break
    time.sleep(.5)
assert ready.exists(), 'Hop did not start its HTTP server'
for _ in range(60):
    if (container/'Documents/.hop-ui-ready').exists():break
    time.sleep(.5)
assert (container/'Documents/.hop-ui-ready').exists(), 'Renderer/native bridge did not initialize'
identity=json.loads(ready.read_text()); base=f'http://127.0.0.1:{identity["port"]}'
def request(path, method='GET', data=None, token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['x-hop-token']=token
    if isinstance(data,dict):data=json.dumps(data).encode()
    with urllib.request.urlopen(urllib.request.Request(base+path,data=data,method=method,headers=headers),timeout=15) as response:return json.load(response)
assert request('/health')['ok']
body='Hop iOS protocol test — фото.txt\n'.encode()
offer={'transferId':'hop-ci-transfer','from':{'id':'hop-ci-sender','name':'CI sender','platform':'win32'},'items':[{'path':'CI-folder/payload.txt','size':len(body),'dir':False}]}
ack=request('/offer','POST',offer); assert ack['accepted']
assert request('/file?t=hop-ci-transfer&i=0','PUT',body,ack['token'])['ok']
received=container/'Documents/CI-folder/payload.txt';assert received.read_bytes()==body
try:
    request('/offer','POST',dict(offer,transferId='hop-ci-invalid',items=[{'path':'../escape','size':0,'dir':False}]))
    raise AssertionError('Traversal accepted')
except urllib.error.HTTPError as error:assert error.code==400
for _ in range(60):
    if outgoing:break
    time.sleep(.5)
assert outgoing==[b'Hop iOS outbound test'], 'Outgoing file bytes did not match'
pathlib.Path('build/protocol-result.json').write_text(json.dumps({'inboundBytes':len(body),'outboundBytes':len(outgoing[0]),'sha256':hashlib.sha256(received.read_bytes()).hexdigest(),'traversalRejected':True}))
time.sleep(3)
run('xcrun','simctl','io',udid,'screenshot','build/Hop-iOS-simulator.png')
print('HTTP receiver, file bytes, path validation, launch: PASS')

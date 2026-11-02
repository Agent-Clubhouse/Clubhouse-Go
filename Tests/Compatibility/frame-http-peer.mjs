// Synthetic loopback-only TLS peer. All content is fake, scoped to the audit directory.
import https from 'node:https';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { X509Certificate, createHash } from 'node:crypto';
const root = process.argv[2];
const directory = mkdtempSync(join(root, 'tls-'));
const key = join(directory, 'key.pem'), cert = join(directory, 'cert.pem');
if (spawnSync('/usr/bin/openssl', ['req','-x509','-newkey','rsa:2048','-nodes','-keyout',key,'-out',cert,'-days','1','-subj','/CN=frame-audit'], {stdio:'ignore'}).status !== 0) process.exit(1);
let mode = 'oversized', framing = 'length', count = 0, wsOpens = 0, attaches = 0;
const server = https.createServer({key:readFileSync(key), cert:readFileSync(cert)}, (req,res) => {
  const url = new URL(req.url, 'https://fixture');
  if(url.pathname.endsWith('/buffer')) { const bytes=readFileSync(join(root,'http-raw-buffer.txt'));res.writeHead(200,{'Content-Type':'text/plain; charset=utf-8','Content-Length':bytes.length});res.end(bytes);return; }
  if (url.pathname === '/control') {
    mode = url.searchParams.get('mode') ?? mode;
    framing = url.searchParams.get('framing') ?? framing;
    res.end('{}'); return;
  }
  if (url.pathname === '/metrics') { res.end(JSON.stringify({count,wsOpens,attaches})); return; }
  count++;
  const before = url.searchParams.get('beforeSeq');
  let file = mode === 'oversized' || (mode === 'poison' && before) ? 'large.json' : mode === 'paged' || mode === 'poison' ? (before ? 'older.json' : 'recent.json') : 'small.json';
  const bytes = readFileSync(join(root,file));
  res.setHeader('Content-Type','application/json');
  if (framing === 'length') res.setHeader('Content-Length', bytes.length);
  else res.setHeader('Transfer-Encoding','chunked');
  res.end(bytes);
});
function frame(socket, bytes, opcode = 1) {
  const length = bytes.length;
  const header = Buffer.alloc(length < 126 ? 2 : length <= 65535 ? 4 : 10);
  header[0] = 0x80 | opcode;
  if(length < 126)header[1]=length;
  else if(length<=65535){header[1]=126;header.writeUInt16BE(length,2);}
  else {header[1]=127;header.writeBigUInt64BE(BigInt(length),2);}
  if(!socket.destroyed)socket.write(Buffer.concat([header,bytes]));
}
server.on('upgrade',(req,socket)=>{
  wsOpens++;
  const accept=createHash('sha1').update(req.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');
  socket.on('error',()=>{});
  frame(socket,readFileSync(join(root,'snapshot.json')));
  let pending=Buffer.alloc(0);
  socket.on('data',chunk=>{
    pending=Buffer.concat([pending,chunk]);
    while(pending.length>=2){
      const opcode=pending[0]&15, masked=!!(pending[1]&128);let length=pending[1]&127, offset=2;
      if(length===126){if(pending.length<4)return;length=pending.readUInt16BE(2);offset=4;}
      else if(length===127){if(pending.length<10)return;length=Number(pending.readBigUInt64BE(2));offset=10;}
      if(masked)offset+=4;if(pending.length<offset+length)return;
      const payload=Buffer.from(pending.subarray(offset,offset+length));
      if(masked)for(let i=0;i<payload.length;i++)payload[i]^=pending[offset-4+(i%4)];
      pending=pending.subarray(offset+length);
      if(opcode===8){socket.end();return;}
      if(opcode===9){frame(socket,payload,10);continue;}
      if(opcode!==1&&opcode!==2)continue;
      let message;try{message=JSON.parse(payload.toString());}catch{continue;}
      if(message.type==='pty:attach'){
        attaches++;
        const file=mode==='pty-short'?'pty-short.json':mode==='pty-empty'?'pty-empty.json':'pty-full.json';
        frame(socket,readFileSync(join(root,file)));
      }
    }
  });
});
server.listen(0, '127.0.0.1', () => process.stdout.write(JSON.stringify({port:server.address().port, pin:new X509Certificate(readFileSync(cert)).fingerprint256})+'\n'));
function cleanup(){ server.close(); rmSync(directory,{recursive:true,force:true}); process.exit(0); }
process.on('SIGTERM',cleanup); process.on('SIGINT',cleanup);

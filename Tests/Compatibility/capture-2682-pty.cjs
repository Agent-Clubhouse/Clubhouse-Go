// Executes unmodified serializer/fallback functions from the pinned temp checkout.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const {execFileSync}=require('node:child_process');
const {createRequire} = require('node:module'), {createHash} = require('node:crypto');
const [repo, out, typescript] = process.argv.slice(2).map(p=>path.resolve(p));
if(execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim()!=='265b3dfefd6a45d837e095750c6e689d822384f7')throw Error('Historical capture requires exact265b3df head');
const ts = require(typescript);
const sourcePath = path.join(repo,'src/main/services/pty-headless-terminal.ts');
const source = fs.readFileSync(sourcePath,'utf8');
const compiled = ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const compiledPath = path.join(repo,'.audit-headless.cjs'); fs.writeFileSync(compiledPath,compiled);
const headless = require(compiledPath), {Terminal} = createRequire(path.join(repo,'package.json'))('@xterm/headless');
const serverSource = fs.readFileSync(path.join(repo,'src/main/services/annex-server.ts'),'utf8');
const ast = ts.createSourceFile('annex-server.ts',serverSource,ts.ScriptTarget.Latest,true);
function declaration(name){
 const statement = ast.statements.find(s=>s.name?.text===name || s.declarationList?.declarations.some(d=>d.name?.text===name));
 if(!statement)throw Error('Missing source declaration '+name);
 return statement.getText(ast);
}
const fallbackSource = ['FRAME_FALLBACKS','lastFrameLimitLog','enforceFrameLimit','PTY_BUFFER_MAX_ENCODED_BYTES','handleAgentBufferRoute'].map(declaration).join('\n');
const context = {Buffer,recordFrameOverLimit(){},appLog(){},ANNEX_FRAME_MAX_BYTES:8*1024*1024,LARGE_FRAME_LOG_INTERVAL_MS:60000,ANNEX_BUFFER_HEADERS:{seq:'X-Seq',cols:'X-Cols',rows:'X-Rows'},ptyManager:{getSerializedBufferSnapshot:async()=>context.rawSnapshot}};
vm.createContext(context);
vm.runInContext(ts.transpileModule(fallbackSource+'\nglobalThis.enforce=enforceFrameLimit;globalThis.bufferRoute=handleAgentBufferRoute;',{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,context);
const write=(name,value)=>fs.writeFileSync(path.join(out,name),JSON.stringify(value));
async function replay(data, suffix=''){
 const t=new Terminal({cols:120,rows:30,scrollback:10000,allowProposedApi:true});
 await new Promise(r=>t.write(data+suffix,r)); const b=t.buffer.active;
 const value={screen:Array.from({length:30},(_,i)=>b.getLine(b.baseY+i)?.translateToString(true)??''),cursorX:b.cursorX,cursorY:b.cursorY,scrollback:b.baseY};t.dispose();return value;
}
(async()=>{
 fs.mkdirSync(out,{recursive:true});headless.reset('agent',{cols:120,rows:30});
 let data='';for(let i=0;i<11000;i++){
  const tag='#'+i;for(let c=0;c<120-tag.length;c++)data+=`\x1b[38;2;${c%256};${(c*7)%256};9m${String.fromCharCode(97+c%26)}`;
  data+=`\x1b[0m${tag}\r\n`;
 }
 data+='prompt> half typed\x1b[30;7H\x1b[?1h\x1b[?2004h\x1b[?25l';
 headless.feedData('agent',data,data.length);
 const full=await headless.snapshot('agent');
 const limited=await headless.snapshot('agent',{maxEncodedBytes:8*1024*1024-1024});
 const ack=s=>({type:'pty:attach:ack',payload:{agentId:'agent',buffer:s.data,outputSeq:s.seq,cols:120,rows:30,...(s.scrollbackLines!==undefined?{scrollbackLines:s.scrollbackLines}:{})}});
 const fullFrame=JSON.stringify(ack(full)); const limitedFrame=context.enforce(JSON.stringify(ack(limited)));
 // This is the real frame fallback, invoked on the unbounded capture (raw-buffer path).
 const emptyFrame=context.enforce(fullFrame);
 fs.writeFileSync(path.join(out,'pty-full.json'),fullFrame);
 fs.writeFileSync(path.join(out,'pty-short.json'),limitedFrame);
 fs.writeFileSync(path.join(out,'pty-empty.json'),emptyFrame);
 const expected=await replay(limited.data), after=await replay(limited.data,'Z');
 const fromFull=await replay(full.data);
 if(JSON.stringify(expected.screen)!==JSON.stringify(fromFull.screen)||expected.cursorX!==fromFull.cursorX||expected.cursorY!==fromFull.cursorY)throw Error('Serializer changed visible state');
 if(Buffer.byteLength(fullFrame)<=16*1024*1024||Buffer.byteLength(limitedFrame)>8*1024*1024||JSON.parse(emptyFrame).payload.buffer!=='')throw Error('Wrong budgets/fallback');
 // Exercise the actual HTTP handler in isolation with a legitimate missing-headless raw fallback.
 context.rawSnapshot={data:full.data,seq:full.seq,cols:120,rows:30};let responseBytes=0;
 await context.bufferRoute({res:{writeHead(){},end(data){responseBytes=Buffer.byteLength(data);fs.writeFileSync(path.join(out,'http-raw-buffer.txt'),data)}}},['','agent']);
 const summary={sha:'265b3dfefd6a45d837e095750c6e689d822384f7',sourceSHA256:createHash('sha256').update(source).digest('hex'),fullFrameBytes:Buffer.byteLength(fullFrame),shortFrameBytes:Buffer.byteLength(limitedFrame),emptyFrameBytes:Buffer.byteLength(emptyFrame),outputSeq:full.seq,scrollbackLines:limited.scrollbackLines,expected,after,fullContainsHideCursor:full.data.includes("\x1b[?25l"),limitedContainsHideCursor:limited.data.includes("\x1b[?25l"),rawHTTPHandlerBytes:responseBytes};
 write('pty-expected.json',summary);console.log(JSON.stringify({...summary,expected:{...expected,screen:'30 rows captured'},after:{...after,screen:'30 rows captured'}}));headless.disposeAll();
})().catch(e=>{console.error(e);headless.disposeAll();process.exitCode=1});

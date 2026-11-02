// Run only the changed raw replay branch at the requested CH head; no empty fallback.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {execFileSync}=require('node:child_process'),{createRequire}=require('node:module'),{createHash}=require('node:crypto');
const [repo,out,typescript]=process.argv.slice(2).map(p=>path.resolve(p));
const sha=execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
if(sha!=='ae2cf9b7d95ed2ae4229221d4be37320686f960a')throw Error('Wrong pinned CH head: '+sha);
const ts=require(typescript),compile=s=>ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const source=fs.readFileSync(path.join(repo,'src/main/services/pty-headless-terminal.ts'),'utf8');
const compiled=path.join(repo,'.audit-raw-headless.cjs');fs.writeFileSync(compiled,compile(source));
const headless=require(compiled),{Terminal}=createRequire(path.join(repo,'package.json'))('@xterm/headless');
const managerSource=fs.readFileSync(path.join(repo,'src/main/services/pty-manager.ts'),'utf8');
const ast=ts.createSourceFile('pty-manager.ts',managerSource,ts.ScriptTarget.Latest,true);
const declaration=ast.statements.find(s=>s.name?.text==='getSerializedBufferSnapshot').getText(ast);
let raw='',seq=0,size={cols:120,rows:30};
const context={Buffer,exports:{},headlessTerminal:headless,sessions:new Map([['agent',{}]]),currentSize:()=>size,getBufferSnapshot:()=>({data:raw,seq})};
vm.createContext(context);vm.runInContext(compile(declaration+'\nglobalThis.capture=getSerializedBufferSnapshot;'),context);
const serverSource=fs.readFileSync(path.join(repo,'src/main/services/annex-server.ts'),'utf8');
const serverAST=ts.createSourceFile('annex-server.ts',serverSource,ts.ScriptTarget.Latest,true);
function serverDeclaration(name){const d=serverAST.statements.find(s=>s.name?.text===name||s.declarationList?.declarations.some(x=>x.name?.text===name));if(!d)throw Error('Missing server declaration '+name);return d.getText(serverAST);}
const serverFunctions=['FRAME_FALLBACKS','lastFrameLimitLog','TERMINAL_UNAVAILABLE','PTY_BUFFER_MAX_ENCODED_BYTES','enforceFrameLimit','readBoundedPtyBuffer','sendPtyError','handleAttachWs'].map(serverDeclaration).join('\n');
let snapshot=null,sent=[];
const serverContext={Buffer,exports:{},ANNEX_FRAME_MAX_BYTES:8*1024*1024,reportFrameOverLimit(){},getAgentExecutionMode:()=> 'pty',ptyManager:{isRunning:()=>true,getShellCwd:()=>undefined,getSerializedBufferSnapshot:async()=>snapshot},safeSend:(_ws,data)=>sent.push(serverContext.enforce(data))};
vm.createContext(serverContext);vm.runInContext(compile(serverFunctions+'\nglobalThis.attach=handleAttachWs;globalThis.enforce=enforceFrameLimit;'),serverContext);
async function actualAck(value){snapshot=value;sent=[];await serverContext.attach({}, {agentId:'agent'});if(sent.length!==1)throw Error('Wrong number of actual handler frames');return sent[0];}

async function replay(data,suffix=''){
 const t=new Terminal({cols:120,rows:30,scrollback:10000,allowProposedApi:true});await new Promise(r=>t.write(data+suffix,r));const b=t.buffer.active;
 const result={screen:Array.from({length:30},(_,i)=>b.getLine(b.baseY+i)?.translateToString(true)??''),cursorX:b.cursorX,cursorY:b.cursorY,scrollback:b.baseY,appCursor:t.modes.applicationCursorKeysMode,bracketedPaste:t.modes.bracketedPasteMode};t.dispose();return result;
}
(async()=>{
 fs.mkdirSync(out,{recursive:true});let tail='';
 for(let i=0;i<11000;i++){const tag='#'+i;for(let c=0;c<120-tag.length;c++)tail+=`\x1b[38;2;${c%256};${(c*7)%256};9m${String.fromCharCode(97+c%26)}`;tail+=`\x1b[0m${tag}\r\n`;}
 tail+='prompt> half typed\x1b[30;7H';const earlier='\x1b[?1h\x1b[?2004h';const results=[];
 for(const kind of ['complete','missingModes','screenOnly']){
  const ending=kind==='screenOnly'?'\x1b[2J\x1b[Hminimal\x1b[2;4H':'';
  const liveRaw=earlier+tail+ending;
  raw=(kind==='missingModes'?'':earlier)+tail+ending;seq=liveRaw.length;
  const budget=kind==='screenOnly'?512:8*1024*1024-1024;
  headless.disposeAll(); // No mirror exists: actual manager must run raw fallback.
  const fitted=await context.capture('agent',{maxEncodedBytes:budget});
  if(!fitted.data||Buffer.byteLength(JSON.stringify(fitted.data))>budget)throw Error('Raw branch did not fit '+kind);
  if(kind==='screenOnly'&&fitted.scrollbackLines!==0)throw Error('Did not reach screen-only');
  const bytes=await actualAck(fitted);const frame=JSON.parse(bytes);if(frame.type!=='pty:attach:ack'||frame.payload.bufferOmitted!==undefined||frame.payload.scrollbackLines===undefined)throw Error('Wrong fitted ack shape');
  const live=await replay(liveRaw),expected=await replay(fitted.data),after=await replay(fitted.data,'Z');
  if(JSON.stringify(expected.screen)!==JSON.stringify(live.screen)||expected.cursorX!==live.cursorX||expected.cursorY!==live.cursorY)throw Error('Raw replay changed visible terminal for '+kind);
  fs.writeFileSync(path.join(out,'raw-'+kind+'.json'),bytes);
  results.push({kind,rawBytes:Buffer.byteLength(raw),encodedBudget:budget,frameBytes:Buffer.byteLength(bytes),scrollbackLines:fitted.scrollbackLines,outputSeq:fitted.seq,live,expected,after});
 }
 // A true over-budget visible screen: raw replay cannot fit even with no scrollback.
 size={cols:120,rows:4000};raw=earlier+tail;seq=raw.length;
 const unfit=await context.capture('agent',{maxEncodedBytes:8*1024*1024-1024});
 if(unfit.data!==raw)throw Error('Unfit-screen branch was not exercised');
 const unfitFailure=await actualAck(unfit);
 const lastResort=serverContext.enforce(JSON.stringify({type:'pty:attach:ack',payload:{agentId:'agent',buffer:raw,outputSeq:seq,...size}}));
 for(const [name,bytes] of [['unfit',unfitFailure],['lastResort',lastResort]]){const value=JSON.parse(bytes);if(value.type!=='error'||value.payload.message!=='terminal_unavailable'||value.payload.op!=='pty:attach'||value.payload.agentId!=='agent')throw Error('Wrong failure');fs.writeFileSync(path.join(out,'failure-'+name+'.json'),bytes);}
 const summary={sha,serverFunctionsSHA256:createHash('sha256').update(serverFunctions).digest('hex'),failureBytes:Buffer.byteLength(unfitFailure),failureScreenSize:size,sourceSHA256:createHash('sha256').update(source).digest('hex'),managerFunctionSHA256:createHash('sha256').update(declaration).digest('hex'),cases:results};
 fs.writeFileSync(path.join(out,'raw-expected.json'),JSON.stringify(summary));
 console.log(JSON.stringify({...summary,cases:results.map(r=>({...r,live:{...r.live,screen:'30 rows captured'},expected:{...r.expected,screen:'30 rows captured'},after:{...r.after,screen:'30 rows captured'}}))}));headless.disposeAll();
})().catch(e=>{console.error(e);headless.disposeAll();process.exitCode=1});

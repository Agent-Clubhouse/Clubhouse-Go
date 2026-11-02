// Actual pinned bounds, broadcast, replay buffer and mobile replay branch; runtime/IO are fake.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const [repo,out,typescript]=process.argv.slice(2).map(p=>path.resolve(p));
const sha=execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim();assert.equal(sha,'0090d8648d2c65b7733aa5e59fe1c3405efd2345');
const ts=require(typescript),compile=s=>ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
function moduleAt(file,require=()=>{throw Error('Unexpected dependency')}){const c={exports:{},Buffer,Date,require};vm.createContext(c);vm.runInContext(compile(fs.readFileSync(path.join(repo,file),'utf8')),c);return c.exports;}
const b=moduleAt('src/main/services/annex-chat-bounds.ts'),replay=moduleAt('src/main/services/annex-event-replay.ts',()=>({validatedTraceparent:()=>undefined}));
const source=fs.readFileSync(path.join(repo,'src/main/services/annex-server.ts'),'utf8'),ast=ts.createSourceFile('server.ts',source,ts.ScriptTarget.Latest,true);
function declaration(name){return ast.statements.find(s=>s.name?.text===name||s.declarationList?.declarations.some(d=>d.name?.text===name)).getText(ast);}
let replayBranch;function walk(n){if(ts.isIfStatement(n)&&n.expression.getText(ast)==="type === 'mobile:replay'")replayBranch=n.getText(ast);ts.forEachChild(n,walk);}walk(ast);assert.ok(replayBranch);
let sent=[];
const c={exports:{},Buffer,...b,eventReplay:replay,validatedTraceparent:()=>undefined,currentRequestTraceparent:()=>undefined,recordFrameOverLimit(){},recordToolInputSize(){},reportFrameOverLimit(){},ANNEX_FRAME_MAX_BYTES:8*1024*1024,mobileCommands:{epoch:'epoch'},broadcastFrame:(_type,frame)=>sent.push(JSON.parse(frame)),safeSend:(_ws,frame)=>sent.push(JSON.parse(c.enforce(frame)))};
vm.createContext(c);vm.runInContext(compile(['FRAME_FALLBACKS','enforceFrameLimit','boundEventPayload','broadcastAndBuffer'].map(declaration).join('\n')+'\nglobalThis.enforce=enforceFrameLimit;globalThis.broadcast=broadcastAndBuffer;globalThis.runReplay=(msg)=>{const type="mobile:replay",ws={};'+replayBranch+'};'),c);
const clone=x=>JSON.parse(JSON.stringify(x)),event=(type,seq,data)=>({agentId:'durable_chat',sessionId:'sess_live',seq,ts:1800000000000+seq,v:2,type,data});
const start=event('tool_call',101,{toolCallId:'cache_tool',toolName:'Write',title:'Write big.ts',kind:'edit',status:'in_progress',locations:[{path:'/work/app/big.ts',line:1}],content:[{type:'text',text:'EARLIER CONTENT'}]});
const original=seq=>event('tool_call_update',seq,{toolCallId:'cache_tool',status:'completed',rawOutput:'x'.repeat(2*1024*1024)});
function broadcast(e){c.broadcast('chat:event',{agentId:e.agentId,event:e});return sent.at(-1);}
function bound(e){return b.boundChatEvent(e,Buffer.byteLength(JSON.stringify({agentId:e.agentId,event:e})));}
function evict(){for(let i=0;i<2000;i++)b.boundChatEvent(event('tool_call_update',i+1,{toolCallId:'evict_'+i,status:'completed'}),2*1024*1024);}
broadcast(start);for(let seq=102;seq<=230;seq++)broadcast(original(seq));
const beforeRestart=clone(sent);assert.equal(beforeRestart.filter(f=>f.payload.event.data.contentMode==='append').length,1);
for(const seq of [102,103])assert.deepEqual(clone(bound(original(seq))),beforeRestart.find(f=>f.payload.event.seq===seq).payload.event);
b._forgetAppendedNotesForTest();for(let seq=231;seq<=233;seq++)broadcast(original(seq));const afterRestart=clone(sent);
assert.equal(afterRestart.filter(f=>f.payload.event.data.contentMode==='append').length,2);
evict();broadcast(original(234));broadcast(original(235));const live=clone(sent);
assert.equal(live.filter(f=>f.payload.event.data.contentMode==='append').length,3);
sent=[];c.runReplay({epoch:'epoch',since:0});const replayed=sent.filter(f=>f.type==='chat:event');assert.equal(replayed.length,live.length);
for(let i=0;i<live.length;i++){const f={...replayed[i]};delete f.replayed;assert.deepEqual(f,live[i]);}
// Re-projecting original transcript events is NOT stable after forgetting; current HTTP tool projection is unbuilt.
b._forgetAppendedNotesForTest();const reprojected=[start,...Array.from({length:134},(_,i)=>original(102+i))].map(bound);
assert.equal(reprojected.filter(e=>e.data.contentMode==='append').length,1);
evict();const rewritten=bound(original(103));assert.equal(rewritten.data.contentMode,'append');assert.equal(live.find(f=>f.payload.event.seq===103).payload.event.data.contentMode,undefined);
// Clearing one ended session selects a fresh note without affecting a different session.
b.forgetAppendedNotes('durable_chat','sess_live');assert.equal(bound(original(236)).data.contentMode,'append');
const note=live.find(f=>f.payload.event.data.contentMode==='append').payload.event.data.content[0].text;
fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,'note-cache.json'),JSON.stringify({sha,note,beforeRestart,afterRestart,live,replayed,reprojected,rewritten,rawPageEvents:[start,original(233),original(234),original(235)]}));
console.log(JSON.stringify({sha,beforeNotes:1,afterRestartNotes:2,afterEvictionNotes:3,replayFrames:replayed.length,replayBodiesIdentical:true,reprojectedNotes:1,evictedRebound103Changed:true}));

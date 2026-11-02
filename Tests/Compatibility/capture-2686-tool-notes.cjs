// Execute the real pinned bounds function; original events/runtime are synthetic.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict'),{execFileSync}=require('node:child_process');
const [repo,out,typescript]=process.argv.slice(2).map(p=>path.resolve(p));
const sha=execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim();assert.equal(sha,'274d3acb975f9160a130df611f4547a3a431c7e0');
const ts=require(typescript),source=fs.readFileSync(path.join(repo,'src/main/services/annex-chat-bounds.ts'),'utf8');
const ctx={exports:{},Buffer,Date};vm.createContext(ctx);vm.runInContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,ctx);
const prior=execFileSync('git',['-C',repo,'show','ef3744bc2a652b6507eb6c69e4fc5ecc7feeb7ac:src/main/services/annex-chat-bounds.ts'],{encoding:'utf8'});
function named(src,name){const ast=ts.createSourceFile('bounds.ts',src,ts.ScriptTarget.Latest,true);return ast.statements.find(s=>s.name?.text===name||s.declarationList?.declarations.some(d=>d.name?.text===name)).getText(ast);}
for(const name of ['boundChatEvent','toolPreviewNote','withNoteIfUncut','previewContent','previewBlock','previewText'])assert.equal(named(source,name),named(prior,name),name+' unchanged');
const priorFixture=execFileSync('git',['-C',repo,'show','ef3744bc2a652b6507eb6c69e4fc5ecc7feeb7ac:test/fixtures/annex-mobile/chat-event-tool-call-preview.json'],{encoding:'utf8'});
assert.equal(fs.readFileSync(path.join(repo,'test/fixtures/annex-mobile/chat-event-tool-call-preview.json'),'utf8'),priorFixture);
const fixture=JSON.parse(fs.readFileSync(path.join(repo,'test/fixtures/annex-mobile/chat-event-tool-call-preview.json'))),bound=ctx.exports.boundChatEvent;
const event=(type,seq,data)=>({agentId:'durable_chat',sessionId:'sess_live',seq,ts:1800000041000+seq,v:2,type,data});
const envelope=(e,seq)=>({type:'chat:event',seq,payload:{agentId:e.agentId,event:e}});
const start=event('tool_call',101,{toolCallId:'append_tool',toolName:'Write',title:'Write big.ts',kind:'edit',status:'in_progress',locations:[{path:'/work/app/big.ts',line:1}],rawInput:{file_path:'/work/app/big.ts'},content:[{type:'text',text:'EARLIER CONTENT\n'+('old line\n'.repeat(1024))}]});
const original=event('tool_call_update',102,{toolCallId:'append_tool',status:'completed',rawOutput:'x'.repeat(2*1024*1024)});
const append=bound(original,Buffer.byteLength(JSON.stringify(original)));assert.equal(append.data.contentMode,'append');assert.equal(append.data.rawOutput,undefined);assert.equal(append.data.content.length,1);
const note=append.data.content[0].text;
const repetitions=Array.from({length:128},(_,i)=>envelope({...append,seq:103+i},1002+i));
const replacementOriginal=event('tool_call_update',300,{toolCallId:'append_tool',status:'completed',content:[{type:'text',text:'REPLACEMENT HEAD\n'+('new line\n'.repeat(150000))+'REPLACEMENT TAIL'}]});
const replacement=bound(replacementOriginal,Buffer.byteLength(JSON.stringify(replacementOriginal)));assert.equal(replacement.data.contentMode,'replace');assert.ok(replacement.data.content[0].text.includes('omitted'));
const callOriginal=event('tool_call',101,{toolCallId:'call_write',toolName:'Write',title:'Write big.ts',kind:'edit',status:'pending',locations:[{path:'/work/app/big.ts',line:1}],rawInput:{file_path:'/work/app/big.ts',content:'c'.repeat(300*1024)}});
const call=bound(callOriginal,Buffer.byteLength(JSON.stringify(callOriginal)));assert.equal(call.data.content[0].text,note);assert.deepEqual(JSON.parse(JSON.stringify(call.data.locations)),callOriginal.data.locations);
fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,'tool-delta.json'),JSON.stringify({sha,note,fixture,actualCall:envelope(call,1000),start:envelope(start,1000),append:envelope(append,1001),repetitions,replacement:envelope(replacement,1132)}));
console.log(JSON.stringify({sha,noteCodeAndFixtureUnchangedFrom:'ef3744bc',noteBytes:Buffer.byteLength(note),appendBytes:Buffer.byteLength(JSON.stringify(append)),repeatCount:repetitions.length,replacementBytes:Buffer.byteLength(JSON.stringify(replacement)),actualCallBytes:Buffer.byteLength(JSON.stringify(call))}));

// One focused new-copy case through actual command guard, not a broad approval rerun.
(async()=>{
 const src=fs.readFileSync(path.join(repo,'src/main/services/mobile-control.ts'),'utf8'),ast=ts.createSourceFile('control.ts',src,ts.ScriptTarget.Latest,true);
 const names=['DENY_OPTION_KINDS','INCOMPLETE_APPROVE_REFUSED','INCOMPLETE_APPROVE_REFUSED_DESKTOP_ONLY','MobileControlError','pendingInteractions','executeChatCommand'];
 const declarations=names.map(n=>ast.statements.find(s=>s.name?.text===n||s.declarationList?.declarations.some(d=>d.name?.text===n)).getText(ast)).join('\n');
 const control={exports:{},boundPendingPermissions:ctx.exports.boundPendingPermissions,hasSupportedDeny:ctx.exports.hasSupportedDeny,isIncompletePermission:ctx.exports.isIncompletePermission};vm.createContext(control);vm.runInContext(ts.transpileModule(declarations,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText,control);
 const original=event('permission_request',8,{requestId:'no-deny',toolCallId:'no-deny-tool',toolName:'Write',title:'Write big.ts',description:'Write big.ts',rawInput:{file_path:'/work/app/big.ts',content:'c'.repeat(300*1024)},options:[{optionId:'allow',kind:'allow_once',label:'Allow'}]});
 const preview=bound(original,Buffer.byteLength(JSON.stringify(original)));assert.ok(preview.data.description.startsWith(ctx.exports.INCOMPLETE_INPUT_WARNING_DESKTOP_ONLY));
 const runtime={kind:'chat',isRunning:()=>true,getSessionId:()=>original.sessionId,readTranscript:async()=>({events:[original]}),getPendingPermissionOptions:()=>original.data.options,respondPermission:async()=>{throw Error('Must not act');}};
 let receipt;try{await control.exports.executeChatCommand({type:'chat.permission',sessionId:original.sessionId,requestId:'no-deny',optionId:'allow'},runtime,async()=>true);throw Error('Must refuse');}catch(e){assert.equal(e.code,'incomplete_representation');receipt={status:e.statusCode,body:{version:1,epoch:'<epoch>',commandId:'<commandId>',status:e.outcome,error:{code:e.code,message:e.detail}}};}
 assert.equal(receipt.body.error.message,'This request is too large to review here. Review it on the desktop.');
 fs.writeFileSync(path.join(out,'desktop-only-copy.json'),JSON.stringify({sha,preview,receipt,warning:ctx.exports.INCOMPLETE_INPUT_WARNING_DESKTOP_ONLY}));console.log('DESKTOP_ONLY_COPY actualGuard=true');
})().catch(e=>{console.error(e);process.exitCode=1});

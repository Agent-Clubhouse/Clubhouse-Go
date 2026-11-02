// Actual pinned CH bounds + chat.permission implementation; only runtime/clock are fake.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const {execFileSync}=require('node:child_process');
const [repo,out,typescript]=process.argv.slice(2,5).map(p=>path.resolve(p));
const goCapture=process.argv[5]&&path.resolve(process.argv[5]);
const sha=execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
assert.equal(sha,'1a684c1cef0d1b7ca7b3da6dff04ceccab500d2a');
const ts=require(typescript),compile=s=>ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
const boundsSource=fs.readFileSync(path.join(repo,'src/main/services/annex-chat-bounds.ts'),'utf8');
const bounds={exports:{},Buffer,Date};vm.createContext(bounds);vm.runInContext(compile(boundsSource),bounds);const b=bounds.exports;
const src=fs.readFileSync(path.join(repo,'src/main/services/mobile-control.ts'),'utf8'),ast=ts.createSourceFile('control.ts',src,ts.ScriptTarget.Latest,true);
const names=['DENY_OPTION_KINDS','INCOMPLETE_APPROVE_REFUSED','MobileControlError','pendingInteractions','executeChatCommand'];
const declarations=names.map(n=>ast.statements.find(s=>s.name?.text===n||s.declarationList?.declarations.some(d=>d.name?.text===n)).getText(ast)).join('\n');
const ctx={exports:{},boundPendingPermissions:b.boundPendingPermissions,isIncompletePermission:b.isIncompletePermission};vm.createContext(ctx);vm.runInContext(compile(declarations),ctx);
const fixture=JSON.parse(fs.readFileSync(path.join(repo,'test/fixtures/annex-mobile/chat-permission-incomplete.json')));
const event=fixture.pendingPermission,clone=x=>JSON.parse(JSON.stringify(x));
async function execute(e,options=e.data.options,optionId='allow',commandOverride){
 let acted=0;const runtime={kind:'chat',isRunning:()=>true,getSessionId:()=>e.sessionId,readTranscript:async()=>({events:[e]}),getPendingPermissionOptions:()=>options,respondPermission:async()=>acted++};
 try {const result=await ctx.exports.executeChatCommand(commandOverride??{type:'chat.permission',sessionId:e.sessionId,requestId:e.data.requestId,optionId},runtime,async()=>true);return {status:200,body:{version:1,epoch:'<epoch>',commandId:'<commandId>',status:'completed',result},acted};}
 catch(e){return {status:e.statusCode,body:{version:1,epoch:'<epoch>',commandId:'<commandId>',status:e.outcome,error:{code:e.code,message:e.detail}},acted};}
}
(async()=>{
 fs.mkdirSync(out,{recursive:true});const cases=[];
 function small(){const e=clone(event);delete e.data.truncated;delete e.data.content;e.data.description='Review small Write';e.data.rawInput={file_path:'/work/app/small.ts',content:'ok'};e.ts=Date.now()+10000;return e;}
 async function test(name,e,options,optionId,expected){b._forgetSentPermissionsForTest(name.startsWith('restart-')?2:0);const result=await execute(e,options,optionId);assert.equal(result.status,expected,name);assert.equal(result.acted,expected===200?1:0);cases.push({name,event:e,options:options??e.data.options,optionId:optionId??'allow',...result});}
 await test('small-normal',small(),undefined,'allow',200);
 const add=small();await test('small-added-option',add,[...add.data.options,{optionId:'extra',kind:'allow_once',label:'Extra'}],'allow',409);
 const relabel=small(),changed=clone(relabel.data.options);changed[0].label='Changed allow';await test('small-changed-label',relabel,changed,'allow',409);
 const reorder=small();await test('small-reordered-live-options',reorder,[...reorder.data.options].reverse(),'allow',409);
 await test('preview-marker-small',clone(event),undefined,'allow',409);
 const remembered=small();b._forgetSentPermissionsForTest(0);b.boundChatEvent(remembered,300*1024);const rememberedResult=await execute(remembered);assert.equal(rememberedResult.status,409);cases.push({name:'preview-record-small',event:remembered,optionId:'allow',...rememberedResult});
 for(const bytes of [4096,4097]){const e=small();e.ts=1;e.data.rawInput.content='';e.data.rawInput.content='x'.repeat(bytes-Buffer.byteLength(JSON.stringify(e.data)));assert.equal(Buffer.byteLength(JSON.stringify(e.data)),bytes);await test('restart-'+bytes,e,undefined,'allow',bytes===4096?200:409);}
 const once=small();once.data.rawInput.content='x'.repeat(8192);once.ts=1;b._forgetSentPermissionsForTest(0);assert.equal((await execute(once)).status,200);b._forgetSentPermissionsForTest(2);const restarted=await execute(once);assert.equal(restarted.status,409);cases.push({name:'once-whole-restart',event:once,optionId:'allow',...restarted});assert.equal((await execute(once,undefined,'deny')).status,200);
 const original=small();original.data.rawInput.content='x'.repeat(300*1024);b._forgetSentPermissionsForTest(0);b.boundChatEvent(original,Buffer.byteLength(JSON.stringify(original)));for(const optionId of ['allow','always','deny']){const result=await execute(original,undefined,optionId);assert.equal(result.status,optionId==='deny'?200:409);cases.push({name:'oversized-'+optionId,event:original,optionId,...result});}
 if(goCapture){const emitted=JSON.parse(fs.readFileSync(goCapture));for(const row of emitted){const c=cases.find(c=>c.name===row.name);assert.ok(c,row.name);b._forgetSentPermissionsForTest(c.name.startsWith('restart-')||c.name==='once-whole-restart'?2:0);if(c.name==='preview-record-small')b.boundChatEvent(c.event,300*1024);const result=await execute(c.event,c.options,c.optionId,row.command);assert.equal(result.status,c.status,c.name+' actual Go command');assert.equal(row.command.optionId,c.optionId);assert.equal(row.command.options,undefined);assert.equal(row.command.label,undefined);}console.log('ACTUAL_GO_COMMANDS '+path.basename(goCapture)+' passed='+emitted.length);}
 fs.writeFileSync(path.join(out,'permission-fixture.json'),JSON.stringify(fixture));fs.copyFileSync(path.join(repo,'test/fixtures/annex-mobile/chat-event-tool-call-preview.json'),path.join(out,'tool-fixture.json'));
 fs.writeFileSync(path.join(out,'commands.json'),JSON.stringify({sha,cases}));console.log(JSON.stringify({sha,cases:cases.map(({name,status,acted})=>({name,status,acted}))}));
})().catch(e=>{console.error(e);process.exitCode=1});

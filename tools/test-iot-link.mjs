// 显式连接隔离的真实 IoT HTTP/MQTT 栈，批准和呈现由软件夹具驱动。
import {readFile,writeFile,mkdir,mkdtemp} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {generateKeyPairSync,createHash,randomUUID,sign} from 'node:crypto';
import assert from 'node:assert/strict';
import {setTimeout as delay} from 'node:timers/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';

const at=process.argv.indexOf('--iot-root');
if(at<0||!process.argv[at+1])throw new Error('需要 --iot-root 显式指定测试依赖');
const iot=resolve(process.argv[at+1]),root=resolve(import.meta.dirname,'..');
const {startActionStack,commandResult}=await import(pathToFileURL(join(iot,'tests/helpers/actions.mjs')));
const {stop,until,freePort}=await import(pathToFileURL(join(iot,'tools/dev-stack.mjs')));
const mtls=process.argv.includes('--mtls');
const agentTest=process.argv.includes('--agent');
const appleAgent=process.argv.includes('--apple-agent');
if(appleAgent && !agentTest)throw new Error('--apple-agent 需要 --agent');
const dotnetAt=process.argv.indexOf('--dotnet-agent');
const dotnetAgent=dotnetAt>=0;
const androidAgent=process.argv.includes('--android-agent');
if(dotnetAgent && (!process.argv[dotnetAt+1] || !process.argv[dotnetAt+1].startsWith('/')))throw new Error('--dotnet-agent 需要绝对可执行文件路径');
if((dotnetAgent || androidAgent) && !agentTest)throw new Error('原生核心 Agent 联调需要 --agent');
const codexAt=process.argv.indexOf('--agent-executable');
if(codexAt>=0 && !process.argv[codexAt+1])throw new Error('缺少显式 Agent 可执行文件');
if(codexAt>=0 && !agentTest)throw new Error('--agent-executable 需要 --agent');
let brokerTls,deviceTls;
if(mtls){
  const directory=await mkdtemp(join(root,'.dev/link-tls-')),exec=promisify(execFile);
  const openssl=async(...args)=>exec('openssl',args,{cwd:directory,maxBuffer:100000});
  await openssl('req','-x509','-newkey','rsa:2048','-nodes','-keyout','ca.key','-out','ca.crt','-days','2','-subj','/CN=LimeLink-isolated-test-CA');
  for(const [name,cn,usage]of[['server','localhost','serverAuth'],['device','device-lamp','clientAuth']]){
    await openssl('req','-new','-newkey','rsa:2048','-nodes','-keyout',name+'.key','-out',name+'.csr','-subj','/CN='+cn);
    await writeFile(join(directory,name+'.ext'),'basicConstraints=CA:FALSE\nextendedKeyUsage='+usage+'\n'+(name==='server'?'subjectAltName=IP:127.0.0.1,DNS:localhost\n':''));
    await openssl('x509','-req','-in',name+'.csr','-CA','ca.crt','-CAkey','ca.key','-CAcreateserial','-out',name+'.crt','-days','2','-extfile',name+'.ext');
  }
  brokerTls={port:await freePort(),ca:join(directory,'ca.crt'),certificate:join(directory,'server.crt'),key:join(directory,'server.key')};
  deviceTls={ca:join(directory,'ca.crt'),certificate:join(directory,'device.crt'),private_key:join(directory,'device.key')};
}
await mkdir(join(root,'.dev'),{recursive:true});
const directory=await mkdtemp(join(root,'.dev/link-integration-'));
let stack;
try{stack=await startActionStack({directory,modelPath:join(root,'contracts/desktop.json'),brokerTls});}
catch(error){
  // 仅输出隔离栈进程日志，不输出配置、环境或证书材料。
  for(const name of ['broker','gateway']){try{console.error(name+': '+(await readFile(join(directory,name+'.log'),'utf8')).slice(-4000));}catch{}}
  throw error;
}
try{
  await stop(stack.lamp);
  const device=(await stack.request('/api/v1/spaces/space-demo/devices/device-lamp')).value;
  const config={mqtt_host:'127.0.0.1',mqtt_port:mtls?brokerTls.port:Number(stack.env.LIMEIOT_MQTT_PORT),space:'space-demo',device:'device-lamp',model_revision:device.model_revision,database:join(stack.directory,'limelink.sqlite'),...(mtls?deviceTls:{allow_loopback_development:true,development_password:stack.env.LIMEIOT_MQTT_PASSWORD})};
  if(agentTest){
    const workspace=join(directory,'agent-workspace');await mkdir(workspace);
    const executable=codexAt>=0?resolve(process.argv[codexAt+1]):join(directory,'codex-fixture');
    if(codexAt<0)await writeFile(executable,await readFile(join(root,'runtime/tests/support/codex_fixture.py')),{mode:0o700});
    config.agent={executable,workspaces:[{id:'work',name:'隔离验收目录',path:workspace,allow_write:false}],timeout_seconds:60};
  }
  const configPath=join(stack.directory,'limelink-device.json');await writeFile(configPath,JSON.stringify(config),{mode:0o600});
  const agent=stack.launch('limelink',join(root,'runtime/target/debug/limelink-runtime'),[configPath]);
  let view,online=false,buffer='';
  agent.stdout.on('data',chunk=>{buffer+=chunk.toString();let index;while((index=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,index);buffer=buffer.slice(index+1);try{const frame=JSON.parse(line);if(frame.type==='view')view=frame;if(frame.type==='connection'&&frame.state==='ready')online=true;}catch{}}});
  await until(()=>online);
  const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'}),jwk=publicKey.export({format:'jwk'});
  const key=Buffer.concat([Buffer.from([4]),Buffer.from(jwk.x,'base64url'),Buffer.from(jwk.y,'base64url')]).toString('hex'),client=randomUUID();
  const base='/api/v1/spaces/space-demo';
  const hash=value=>createHash('sha256').update(value).digest('hex');
  function input(kind,payload){const nonce=randomUUID(),expires_at=Math.floor(Date.now()/1000)+20,text=JSON.stringify(payload),message=['limelink.exchange/v1','space-demo','device-lamp',device.model_revision,client,kind,nonce,expires_at,hash(text)].join('\n');return{client_id:client,public_key:key,kind,nonce,expires_at,payload:text,signature:sign('sha256',Buffer.from(message),privateKey).toString('hex')};}
  const submit=async(kind,payload,original)=>{
    const request=original??{key:randomUUID(),body:{device_id:'device-lamp',model_revision:device.model_revision,expires_at:new Date(Date.now()+10000).toISOString(),operation:{type:'action.invoke',path:kind.startsWith('agent.')?'agent.exchange':'link.exchange',value:input(kind,payload)}}};
    const accepted=await stack.request(base+'/commands',{method:'POST',headers:{'Content-Type':'application/json','Idempotency-Key':request.key},body:JSON.stringify(request.body)});
    assert.ok([200,201,202].includes(accepted.status),JSON.stringify(accepted.value));
    const command=await commandResult(stack,accepted.value.command_id);
    assert.equal(command.evidence.completion,'submitted');
    return{request,command,response:JSON.parse(command.evidence.output.response)};
  };
  const blocked=await submit('card',{text:'must not appear',ttl:60});assert.equal(blocked.response.error,'pairing_required');
  const pair=await submit('pair',{name:'隔离手机客户端'});assert.equal(pair.response.value.state,'pending');
  await until(()=>view?.peers?.some(p=>p.id===client&&p.state==='pending'));
  agent.stdin.write(JSON.stringify({type:'approve',id:client})+'\n');
  await until(()=>view.peers.some(p=>p.id===client&&p.state==='approved'));
  assert.equal((await submit('status',{})).response.value.state,'approved');
  const card=await submit('card',{text:'LimeLink HTTP → MQTT → 本机耐久卡片',ttl:60});assert.equal(card.response.value.presentation,'queued');
  await until(()=>view.cards.some(c=>c.id===card.command.command_id));
  const duplicate=await submit('card',{},card.request);assert.equal(duplicate.command.command_id,card.command.command_id);assert.equal(view.cards.length,1);
  const original=await stack.request(base+'/commands/by-key/'+card.request.key);assert.equal(original.value.command_id,card.command.command_id);
  agent.stdin.write(JSON.stringify({type:'presented',id:card.command.command_id})+'\n');await until(()=>view.cards.some(c=>c.state==='presented'));
  assert.equal((await submit('status',{})).response.value.cards[0].state,'presented');
  await submit('session_create',{id:'cross-screen-session',text:'原会话草稿',ttl:60});
  const claim=await submit('session_claim',{id:'cross-screen-session',revision:1});assert.equal(claim.response.value.revision,2);
  assert.equal((await submit('session_write',{id:'cross-screen-session',revision:1,text:'旧修订'})).response.error,'revision_conflict');
  assert.equal((await submit('session_write',{id:'cross-screen-session',revision:2,text:'新修订'})).response.ok,true);
  assert.equal((await submit('session_release',{id:'cross-screen-session',revision:3})).response.ok,true);
  agent.stdin.write(JSON.stringify({type:'session_claim',id:'cross-screen-session',revision:4})+'\n');
  await until(()=>view.sessions.some(s=>s.id==='cross-screen-session'&&s.writer==='local-desktop'));
  assert.equal((await submit('session_release',{id:'cross-screen-session',revision:5})).response.error,'writer_busy');
  agent.stdin.write(JSON.stringify({type:'session_write',id:'cross-screen-session',revision:5,text:'电脑接续的草稿'})+'\n');
  await until(()=>view.sessions.some(s=>s.revision===6));
  agent.stdin.write(JSON.stringify({type:'session_release',id:'cross-screen-session',revision:6})+'\n');
  await until(()=>view.sessions.some(s=>s.revision===7));
  assert.equal((await submit('session_claim',{id:'cross-screen-session',revision:7})).response.value.text,'电脑接续的草稿');
  await submit('content_put',{id:'note',text:'今日专注',sha256:hash('今日专注'),ttl:60});await until(()=>view.contents.some(c=>c.id==='note'));
  await submit('content_remove',{id:'note'});await until(()=>view.contents.length===0);
  agent.stdin.write(JSON.stringify({type:'revoke',id:client})+'\n');await until(()=>view.peers.some(p=>p.state==='revoked'));
  const denied=await submit('card',{text:'revoked',ttl:60});assert.equal(denied.response.error,'pairing_not_approved');
  assert.equal((await submit('pair',{name:'隔离手机客户端'})).response.value.state,'revoked');
  assert.equal((await submit('pair',{name:'明确重新申请',reapply:true})).response.value.state,'pending');
  assert.equal((await submit('card',{text:'not approved again',ttl:60})).response.error,'pairing_not_approved');
  await until(()=>view.peers.some(p=>p.id===client&&p.state==='pending'));
  agent.stdin.write(JSON.stringify({type:'approve',id:client})+'\n');
  await until(()=>view.peers.some(p=>p.id===client&&p.state==='approved'));
  assert.equal((await submit('session_claim',{id:'cross-screen-session',revision:8})).response.error,'session_not_found');
  assert.equal((await submit('card',{},denied.request)).response.error,'pairing_not_approved');
  assert.equal((await submit('card',{text:'明确批准后的新卡片',ttl:60})).response.ok,true);
  let agentReport;
  if(agentTest){
    const capabilities=await submit('agent.capabilities',{});assert.equal(capabilities.response.value.local_approval_required,true);
    const text=codexAt>=0?'Do not use tools, read files, or access external resources. Reply with only the ASCII token on the next line, without punctuation or Markdown:\nLIMELINK_AGENT_OK':'normal';
    const id=randomUUID();
    const queued=await submit('agent.submit',{id,workspace_id:'work',text,sandbox:'read-only'});
    assert.equal(queued.response.value.state,'awaiting_approval');assert.equal(queued.response.value.session_id,null);
    const duplicate=await submit('agent.submit',{},queued.request);assert.equal(duplicate.command.command_id,queued.command.command_id);
    await until(()=>view?.agent?.runs?.some(r=>r.id===id && r.state==='awaiting_approval'));
    assert.equal(view.agent.runs.filter(r=>r.id===id).length,1);
    agent.stdin.write(JSON.stringify({type:'agent_approve',id})+'\n');
    const finished=await until(()=>{const r=view?.agent?.runs?.find(r=>r.id===id);return r && ['succeeded','failed','unknown'].includes(r.state) && r;},65000);
    assert.equal(finished.state,'succeeded',finished.error??'Agent did not finish');
    let after=0,reply='';
    for(let page=0;page<64;page++){
      const status=(await submit('agent.status',{id,after})).response.value;
      assert.equal(status.id,id);assert.equal(status.state,'succeeded');
      for(const event of status.events)if(event.kind==='message')reply+=event.text;
      after=status.cursor;if(status.events.length<4)break;
    }
    assert.equal(reply.trim(),codexAt>=0?'LIMELINK_AGENT_OK':'真实协议夹具'.repeat(100));
    const resumed=randomUUID();
    await submit('agent.submit',{id:resumed,workspace_id:'work',text,sandbox:'read-only',resume_from:id});
    agent.stdin.write(JSON.stringify({type:'agent_approve',id:resumed})+'\n');
    const resumedResult=await until(()=>{const r=view?.agent?.runs?.find(r=>r.id===resumed);return r && ['succeeded','failed','unknown'].includes(r.state) && r;},65000);
    assert.equal(resumedResult.state,'succeeded',resumedResult.error??'Resume did not finish');assert.equal(resumedResult.session_id,finished.session_id);
    if(codexAt<0){
      const cancelled=randomUUID();await submit('agent.submit',{id:cancelled,workspace_id:'work',text:'interrupt',sandbox:'read-only'});
      agent.stdin.write(JSON.stringify({type:'agent_approve',id:cancelled})+'\n');
      await until(()=>view.agent.runs.some(r=>r.id===cancelled && r.state==='running'));
      assert.equal((await submit('agent.cancel',{id:cancelled})).response.value.state,'cancelling');
      await until(()=>view.agent.runs.some(r=>r.id===cancelled && r.state==='cancelled'));
    }
    if(appleAgent || dotnetAgent || androidAgent){
      const peers=new Set(),runs=new Set();
      const approve=setInterval(()=>{
        for(const peer of view?.peers??[])if(peer.state==='pending' && !peers.has(peer.id)){peers.add(peer.id);agent.stdin.write(JSON.stringify({type:'approve',id:peer.id})+'\n');}
        for(const run of view?.agent?.runs??[])if(run.state==='awaiting_approval' && !runs.has(run.id)){runs.add(run.id);agent.stdin.write(JSON.stringify({type:'agent_approve',id:run.id})+'\n');}
      },100);
      try{
        const env={...process.env,LIMELINK_AGENT_CHECK_ENDPOINT:stack.env.LIMEIOT_ENDPOINT,LIMELINK_AGENT_CHECK_TOKEN:stack.env.LIMEIOT_TOKEN,LIMELINK_AGENT_CHECK_REAL:codexAt>=0?'1':'0'};
        if(appleAgent){
          const result=await promisify(execFile)('swift',['run','-j','4','AgentChecks'],{cwd:root,env,timeout:150000,maxBuffer:100000});
          const record=JSON.parse(result.stdout.trim().split('\n').at(-1));assert.equal(record.passed,true);assert.equal(record.workbench_model,true);
        }
        if(dotnetAgent){
          const result=await promisify(execFile)(process.argv[dotnetAt+1],['run','--project','apps/windows/LimeLink.Core.Checks'],{cwd:root,env,timeout:150000,maxBuffer:100000});
          const record=JSON.parse(result.stdout.trim().split('\n').at(-1));assert.equal(record.passed,true);assert.equal(record.product_client,'dotnet');
        }
        if(androidAgent){
          await promisify(execFile)('sh',['gradlew','--no-daemon',':core:test','--tests','run.limeai.link.core.AgentLiveTest','--rerun-tasks'],{cwd:join(root,'apps/android'),env,timeout:180000,maxBuffer:100000});
          const xml=await readFile(join(root,'apps/android/core/build/test-results/test/TEST-run.limeai.link.core.AgentLiveTest.xml'),'utf8');
          assert.match(xml,/tests="1"/);assert.match(xml,/skipped="0"/);assert.match(xml,/failures="0"/);assert.match(xml,/errors="0"/);
          const record=JSON.parse(xml.match(/\{"passed":true,"product_client":"android"[^\n]+\}/)?.[0]??'{}');assert.equal(record.passed,true);
        }
      }finally{clearInterval(approve);}
    }
    agentReport={independent_action:true,local_approval:true,original_submit_no_duplicate:true,durable_run_query:true,paginated_reply:true,explicit_session_resume:true,interrupt_confirmed:codexAt<0,real_agent:codexAt>=0,fixture:codexAt<0,apple_workbench_model:appleAgent,dotnet_product_client:dotnetAgent,android_product_client:androidAgent};
  }
  const sdk=JSON.parse(await readFile(join(root,'contracts/iot-sdk.lock.json'),'utf8'));
  const files=['runtime/src/lib.rs','runtime/src/main.rs','runtime/src/agent.rs','runtime/src/agent/codex.rs','runtime/src/agent/tools.rs','runtime/tests/agent.rs','runtime/tests/agent_protocol.rs','runtime/tests/support/codex_fixture.py','runtime/Cargo.lock','contracts/desktop.json','tools/test-iot-link.mjs'];
  if(appleAgent)files.push('Package.swift','packages/apple/AgentTests/AgentChecks.swift','packages/apple/Sources/LimeLinkCore/AgentClient.swift','packages/apple/Sources/LimeLinkCore/LinkClient.swift','packages/apple/Sources/LimeLinkUI/WorkbenchModel.swift');
  if(dotnetAgent)files.push('apps/windows/LimeLink.Core/AgentClient.cs','apps/windows/LimeLink.Core/LinkClient.cs','apps/windows/LimeLink.Core.Checks/Program.cs','apps/windows/LimeLink.Core.Checks/AgentLiveChecks.cs');
  if(androidAgent)files.push('apps/android/core/src/main/kotlin/run/limeai/link/core/AgentClient.kt','apps/android/core/src/main/kotlin/run/limeai/link/core/LinkClient.kt','apps/android/core/src/test/kotlin/run/limeai/link/core/AgentLiveTest.kt','apps/android/core/build.gradle.kts');
  const sources=Object.fromEntries(await Promise.all(files.map(async file=>[file,hash(await readFile(join(root,file)))])));
  const binaryDirectory=process.env.LIMEIOT_TEST_TARGET_DIR??join(iot,'target/debug');
  const binaries=Object.fromEntries(await Promise.all(['limeiot-gateway','limeiot-model-validator','limeiot-simulator'].map(async file=>[file,hash(await readFile(join(binaryDirectory,file)))])));
  binaries['limelink-runtime']=hash(await readFile(join(root,'runtime/target/debug/limelink-runtime')));
  const report={scope:'隔离真实 IoT HTTP/MQTT 与 Rust 本机运行时；软件批准/呈现夹具',passed:true,verified_at:new Date().toISOString(),sdk_revision:sdk.head,sdk_worktree_overlay:sdk.worktree_overlay,sources,binaries,device_model_revision:device.model_revision,pairing:true,explicit_approval:true,signature:true,original_command_recovery:true,duplicate_no_second_card:true,submission_and_presentation_separate:true,session_cas:true,desktop_session_handoff:true,content_hash_and_remove:true,revocation:true,explicit_reapply:true,reapply_does_not_resurrect_old_session:true,native_ui:false,physical_phone:false,device_mtls:mtls};
  await mkdir(join(root,'docs/evidence'),{recursive:true});await writeFile(join(root,'docs/evidence/'+(mtls?'iot-runtime-mtls-integration.json':'iot-runtime-integration.json')),JSON.stringify(report,null,2)+'\n');
  if(agentReport){const agentEvidence={...report,scope:'隔离 IoT HTTP/MQTT、Rust Agent 运行时与 '+(codexAt>=0?'真实 Codex App Server':'进程协议夹具'),agent:agentReport};await writeFile(join(root,'docs/evidence/'+(codexAt>=0?'agent-gateway-live.json':'agent-gateway-integration.json')),JSON.stringify(agentEvidence,null,2)+'\n');console.log(JSON.stringify(agentEvidence));}
  else console.log(JSON.stringify(report));
}finally{await stack.close();}

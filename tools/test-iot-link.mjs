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
const stack=await startActionStack({directory:await mkdtemp(join(root,'.dev/link-integration-')),modelPath:join(root,'contracts/desktop.json'),brokerTls});
try{
  await stop(stack.lamp);
  const device=(await stack.request('/api/v1/spaces/space-demo/devices/device-lamp')).value;
  const config={mqtt_host:'127.0.0.1',mqtt_port:mtls?brokerTls.port:Number(stack.env.LIMEIOT_MQTT_PORT),space:'space-demo',device:'device-lamp',model_revision:device.model_revision,database:join(stack.directory,'limelink.sqlite'),...(mtls?deviceTls:{allow_loopback_development:true,development_password:stack.env.LIMEIOT_MQTT_PASSWORD})};
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
    const request=original??{key:randomUUID(),body:{device_id:'device-lamp',model_revision:device.model_revision,expires_at:new Date(Date.now()+10000).toISOString(),operation:{type:'action.invoke',path:'link.exchange',value:input(kind,payload)}}};
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
  assert.equal((await submit('card',{text:'revoked',ttl:60})).response.error,'pairing_not_approved');
  const sdk=JSON.parse(await readFile(join(root,'contracts/iot-sdk.lock.json'),'utf8'));
  const files=['runtime/src/lib.rs','runtime/src/main.rs','runtime/Cargo.lock','contracts/desktop.json','tools/test-iot-link.mjs'];
  const sources=Object.fromEntries(await Promise.all(files.map(async file=>[file,hash(await readFile(join(root,file)))])));
  const binaryDirectory=process.env.LIMEIOT_TEST_TARGET_DIR??join(iot,'target/debug');
  const binaries=Object.fromEntries(await Promise.all(['limeiot-gateway','limeiot-model-validator','limeiot-simulator'].map(async file=>[file,hash(await readFile(join(binaryDirectory,file)))])));
  binaries['limelink-runtime']=hash(await readFile(join(root,'runtime/target/debug/limelink-runtime')));
  const report={scope:'隔离真实 IoT HTTP/MQTT 与 Rust 本机运行时；软件批准/呈现夹具',passed:true,verified_at:new Date().toISOString(),sdk_revision:sdk.head,sdk_worktree_overlay:sdk.worktree_overlay,sources,binaries,device_model_revision:device.model_revision,pairing:true,explicit_approval:true,signature:true,original_command_recovery:true,duplicate_no_second_card:true,submission_and_presentation_separate:true,session_cas:true,desktop_session_handoff:true,content_hash_and_remove:true,revocation:true,native_ui:false,physical_phone:false,device_mtls:mtls};
  await mkdir(join(root,'docs/evidence'),{recursive:true});await writeFile(join(root,'docs/evidence/'+(mtls?'iot-runtime-mtls-integration.json':'iot-runtime-integration.json')),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{await stack.close();}

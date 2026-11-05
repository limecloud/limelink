// 用真实 macOS 窗口批准和展示；手机输入由软件夹具代替，测试不会写入 UI 私有 stdin。
import {readFile,writeFile,mkdir,mkdtemp} from 'node:fs/promises';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {generateKeyPairSync,createHash,randomUUID,sign} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import assert from 'node:assert/strict';

const index=process.argv.indexOf('--iot-root');if(index<0)throw new Error('需要显式 --iot-root');
const root=resolve(import.meta.dirname,'..'),iot=resolve(process.argv[index+1]);
const {startActionStack,commandResult}=await import(pathToFileURL(join(iot,'tests/helpers/actions.mjs')));
const {stop,until,freePort}=await import(pathToFileURL(join(iot,'tools/dev-stack.mjs')));
await mkdir(join(root,'.dev'),{recursive:true});const directory=await mkdtemp(join(root,'.dev/native-ui-'));
await writeFile(join(root,'.dev/macos-ui-finish'),'pending');
const exec=promisify(execFile);const openssl=(...args)=>exec('openssl',args,{cwd:directory,maxBuffer:100000});
await openssl('req','-x509','-newkey','rsa:2048','-nodes','-keyout','ca.key','-out','ca.crt','-days','2','-subj','/CN=LimeLink-native-isolated-CA');
for(const [name,cn,usage]of[['server','localhost','serverAuth'],['device','device-lamp','clientAuth']]){
  await openssl('req','-new','-newkey','rsa:2048','-nodes','-keyout',name+'.key','-out',name+'.csr','-subj','/CN='+cn);
  await writeFile(join(directory,name+'.ext'),'basicConstraints=CA:FALSE\nextendedKeyUsage='+usage+'\n'+(name==='server'?'subjectAltName=IP:127.0.0.1,DNS:localhost\n':''));
  await openssl('x509','-req','-in',name+'.csr','-CA','ca.crt','-CAkey','ca.key','-CAcreateserial','-out',name+'.crt','-days','2','-extfile',name+'.ext');
}
const port=await freePort();
const stack=await startActionStack({directory,modelPath:join(root,'contracts/desktop.json'),brokerTls:{port,ca:join(directory,'ca.crt'),certificate:join(directory,'server.crt'),key:join(directory,'server.key')}});
let database;
try{
  const device=(await stack.request('/api/v1/spaces/space-demo/devices/device-lamp')).value;await stop(stack.lamp);
  const config={mqtt_host:'127.0.0.1',mqtt_port:port,space:'space-demo',device:'device-lamp',model_revision:device.model_revision,database:join(directory,'limelink.sqlite'),ca:join(directory,'ca.crt'),certificate:join(directory,'device.crt'),private_key:join(directory,'device.key')};
  const configuration=join(directory,'device.json');await writeFile(configuration,JSON.stringify(config),{mode:0o600});
  const progress=async step=>{await writeFile(join(root,'.dev/macos-ui-progress.json'),JSON.stringify({step}));console.log(step);};
  stack.launch('macos',join(root,'.dev/artifacts/LimeLink.app/Contents/MacOS/LimeLink'),[],{LIMELINK_RUNTIME_CONFIG:configuration});
  await progress('请在原生窗口选择“本机终端”');
  await until(async()=>{const next=(await stack.request('/api/v1/spaces/space-demo/devices/device-lamp')).value;return next.ready&&next.boot_id!==device.boot_id;},600000);
  database=new DatabaseSync(config.database,{readOnly:true});
  const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'}),jwk=publicKey.export({format:'jwk'});
  const key=Buffer.concat([Buffer.from([4]),Buffer.from(jwk.x,'base64url'),Buffer.from(jwk.y,'base64url')]).toString('hex'),client=randomUUID();
  const hash=value=>createHash('sha256').update(value).digest('hex');
  const submit=async(kind,payload)=>{
    const nonce=randomUUID(),expires_at=Math.floor(Date.now()/1000)+20,text=JSON.stringify(payload);
    const message=['limelink.exchange/v1','space-demo','device-lamp',device.model_revision,client,kind,nonce,expires_at,hash(text)].join('\n');
    const value={client_id:client,public_key:key,kind,nonce,expires_at,payload:text,signature:sign('sha256',Buffer.from(message),privateKey).toString('hex')};
    const response=await stack.request('/api/v1/spaces/space-demo/commands',{method:'POST',headers:{'Content-Type':'application/json','Idempotency-Key':randomUUID()},body:JSON.stringify({device_id:'device-lamp',model_revision:device.model_revision,expires_at:new Date(Date.now()+10000).toISOString(),operation:{type:'action.invoke',path:'link.exchange',value}})});
    assert.ok([200,201,202].includes(response.status));const result=await commandResult(stack,response.value.command_id);return JSON.parse(result.evidence.output.response);
  };
  assert.equal((await submit('pair',{name:'原生界面验证手机'})).value.state,'pending');
  await progress('请核对原生界面中的指纹并点击“核对后批准”');
  await until(()=>database.prepare('SELECT state FROM peers WHERE id=?').get(client)?.state==='approved',120000);
  assert.equal((await submit('card',{text:'手机的灵感，电脑接着做。\nLimeLink 原生窗口验证',ttl:300})).ok,true);
  await progress('等待原生窗口实际显示卡片');
  await until(()=>database.prepare("SELECT count(*) AS count FROM cards WHERE state='presented'").get().count===1,60000);
  assert.equal((await submit('status',{})).value.cards[0].state,'presented');
  await submit('session_create',{id:'native-session',text:'手机建立的草稿',ttl:600});
  await progress('请在原生会话区域取得资格、输入“电脑接续完成”并提交，然后释放资格');
  await until(()=>database.prepare('SELECT text,writer FROM sessions WHERE id=?').get('native-session')?.text==='电脑接续完成'&&database.prepare('SELECT writer FROM sessions WHERE id=?').get('native-session')?.writer===null,600000);
  const revision=database.prepare('SELECT revision FROM sessions WHERE id=?').get('native-session').revision;
  assert.equal((await submit('session_claim',{id:'native-session',revision})).value.text,'电脑接续完成');
  const sdk=JSON.parse(await readFile(join(root,'contracts/iot-sdk.lock.json'),'utf8'));
  const report={passed:true,verified_at:new Date().toISOString(),scope:'macOS 本机批准、原生卡片实际呈现及会话编辑；手机为 Node 签名夹具',sdk_revision:sdk.head,native_ui:true,physical_phone:false,user_https_ui:false,device_mtls:true,approval_via_native_window:true,presentation_via_native_window:true,desktop_session_handoff:true,app_binary_sha256:hash(await readFile(join(root,'.dev/artifacts/LimeLink.app/Contents/MacOS/LimeLink'))),runtime_binary_sha256:hash(await readFile(join(root,'.dev/artifacts/LimeLink.app/Contents/MacOS/limelink-runtime')))};
  await writeFile(join(root,'docs/evidence/macos-native-ui.json'),JSON.stringify(report,null,2)+'\n');
  await progress('已通过；等待截图后在 .dev/macos-ui-finish 写入 done 关闭隔离应用');
  await until(async()=>await readFile(join(root,'.dev/macos-ui-finish'),'utf8')==='done',600000);
}finally{database?.close();await stack.close();}

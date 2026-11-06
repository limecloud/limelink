import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,stat} from 'node:fs/promises';
import {execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';

test('实际工作台模型：浏览器批准、产品配对、丢响应、重启、原卡片恢复与独立退出',{timeout:480000,skip:!process.env.LIMELINK_TEST_CLOUD_DIRECTORY},async()=>{
  const root=path.resolve(import.meta.dirname,'..'),iot=process.env.LIMELINK_TEST_IOT_ROOT,directory=process.env.LIMELINK_TEST_CLOUD_DIRECTORY;
  const {startActionStack}=await import(pathToFileURL(path.join(iot,'tests/helpers/actions.mjs')));
  const {stop,until,freePort,binaryDirectory}=await import(pathToFileURL(path.join(iot,'tools/dev-stack.mjs')));
  const {origin,post,cloudClient,fixture}=await import(pathToFileURL(path.join(iot,'tests/helpers/control.mjs')));
  const {chromium}=await import(pathToFileURL(path.join(root,'site/node_modules/@playwright/test/index.mjs')));
  const exec=promisify(execFile),hash=data=>createHash('sha256').update(data).digest('hex');
  const files=['packages/apple/Sources/LimeLinkUI/WorkbenchModel.swift','packages/apple/Sources/LimeLinkUI/WorkbenchView.swift','packages/apple/Sources/LimeLinkCore/CloudLinkClient.swift','packages/apple/WorkbenchTests/WorkbenchChecks.swift','packages/apple/WorkbenchTests/CloudLiveChecks.swift','tools/cloud-workbench.test.mjs','tools/test-cloud-workbench.mjs','contracts/iot-sdk.lock.json','contracts/desktop.json','runtime/src/lib.rs','runtime/src/main.rs'];
  const fingerprints=()=>Promise.all(files.map(async file=>[file,hash(await readFile(path.join(root,file)))]));
  const beforeSources=Object.fromEntries(await fingerprints());
  const openssl=(...args)=>exec('openssl',args,{cwd:directory,maxBuffer:100000});
  await openssl('req','-x509','-newkey','rsa:2048','-nodes','-keyout','ca.key','-out','ca.crt','-days','2','-subj','/CN=LimeLink-cloud-workbench-isolated');
  for(const [name,cn,usage]of[['server','localhost','serverAuth'],['device','device-lamp','clientAuth']]){
    await openssl('req','-new','-newkey','rsa:2048','-nodes','-keyout',name+'.key','-out',name+'.csr','-subj','/CN='+cn);
    await writeFile(path.join(directory,name+'.ext'),'basicConstraints=CA:FALSE\nextendedKeyUsage='+usage+'\n'+(name==='server'?'subjectAltName=IP:127.0.0.1,DNS:localhost\n':''));
    await openssl('x509','-req','-in',name+'.csr','-CA','ca.crt','-CAkey','ca.key','-CAcreateserial','-out',name+'.crt','-days','2','-extfile',name+'.ext');
  }
  const scratch=path.join(directory,'client');await mkdir(scratch,{mode:0o700});
  let stack,child,browser;
  try{
    const key=path.join(directory,'identity.pk8');await exec(path.join(binaryDirectory,'limeiot-gateway'),['identity-init',key]);
    const tls={port:await freePort(),ca:path.join(directory,'ca.crt'),certificate:path.join(directory,'server.crt'),key:path.join(directory,'server.key')};
    stack=await startActionStack({directory,modelPath:path.join(root,'contracts/desktop.json'),brokerTls:tls,gatewayEnv:{LIMEIOT_CONTROL_ALLOWED_ORIGINS:origin,LIMEIOT_GATEWAY_KEY_FILE:key,LIMEIOT_CONTROL_CA_FILE:process.env.LIMEIOT_TEST_CONTROL_CA_FILE,LIMEIOT_CONTROL_RELAY_ENABLED:'1'}});
    const base='/api/v1/spaces/space-demo';const device=(await stack.request(base+'/devices/device-lamp')).value;await stop(stack.lamp);
    const config={mqtt_host:'127.0.0.1',mqtt_port:tls.port,space:'space-demo',device:'device-lamp',model_revision:device.model_revision,database:path.join(directory,'limelink.sqlite'),ca:tls.ca,certificate:path.join(directory,'device.crt'),private_key:path.join(directory,'device.key')};
    const configuration=path.join(directory,'device.json');await writeFile(configuration,JSON.stringify(config),{mode:0o600});
    const agent=stack.launch('limelink',path.join(root,'runtime/target/debug/limelink-runtime'),[configuration]);
    let view,online=false,buffer='';agent.stdout.on('data',chunk=>{buffer+=chunk;let at;while((at=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,at);buffer=buffer.slice(at+1);const frame=JSON.parse(line);if(frame.type==='view')view=frame;if(frame.type==='connection'&&frame.state==='ready')online=true;}});
    await until(()=>online);
    const cloud=await cloudClient(),pair=await cloud.pair(),space=pair.pairing.space_id;
    const local=(await stack.request(base+'/control-pairings',post({control_origin:pair.control_origin,pairing_id:pair.pairing.pairing_id,code:pair.code},'cloud-workbench-pair'))).value;
    const review=await until(async()=>{const value=(await stack.request(base+'/control-pairings/'+local.link_id)).value;return value.status==='awaiting_approval'&&value});
    await stack.request(base+'/control-pairings/'+local.link_id+'/approve',post({review_revision:review.review_revision}));
    const binding=(await until(async()=>{const value=(await stack.request(base+'/control-pairings/'+local.link_id)).value;return value.status==='active'&&value})).binding;
    await until(async()=>(await cloud.connection(binding)).connected);
    child=spawn('swift',['run','-j','4','WorkbenchChecks'],{cwd:root,env:{...process.env,LIMELINK_CLOUD_WORKBENCH_DIRECTORY:scratch,LIMELINK_CLOUD_WORKBENCH_SPACE:space},stdio:['ignore','pipe','pipe']});
    let output='',finished=false;child.stdout.on('data',chunk=>{output+=chunk});child.stderr.on('data',chunk=>{output+=chunk});
    const done=new Promise(resolve=>{child.once('error',error=>{finished=true;resolve({error})});child.once('exit',code=>{finished=true;resolve({code})})});
    async function waitFile(name){const deadline=Date.now()+90000;while(Date.now()<deadline){try{return await readFile(path.join(scratch,name),'utf8')}catch(error){if(error.code!=='ENOENT')throw error}if(finished)throw new Error('workbench exited before '+name+': '+output);await delay(100)}throw new Error('workbench marker timeout: '+name)}
    const login=JSON.parse(await waitFile('login.json'));assert.equal((await stat(path.join(scratch,'login.json'))).mode&0o777,0o600);assert.equal(login.verification_uri,origin+'/console/?native='+login.authorization_id);
    browser=await chromium.launch({headless:true,executablePath:process.env.LIMEIOT_BROWSER_EXECUTABLE});const context=await browser.newContext({ignoreHTTPSErrors:true}),page=await context.newPage();
    await page.goto(login.verification_uri);await page.getByLabel('实例凭据',{exact:true}).fill((await readFile(process.env.LIMEIOT_TEST_CONTROL_TOKEN_FILE,'utf8')).trim());await page.getByRole('button',{name:'登录私有实例',exact:true}).click();
    await page.getByLabel('应用中的授权码',{exact:true}).fill(login.user_code);await page.getByRole('button',{name:'批准登录',exact:true}).click();await page.getByText('请求已结束，请返回应用。',{exact:true}).waitFor();
    await writeFile(path.join(scratch,'approved'),'approved');
    await waitFile('pair-waiting');const peer=await until(()=>view?.peers?.find(p=>p.state==='pending'));
    assert.equal(peer.name,'真实云工作台模型夹具');assert.equal(peer.fingerprint,await readFile(path.join(scratch,'fingerprint.txt'),'utf8'));
    agent.stdin.write(JSON.stringify({type:'approve',id:peer.id})+'\n');await until(()=>view.peers.some(p=>p.id===peer.id&&p.state==='approved'));
    await writeFile(path.join(scratch,'paired'),'paired');await waitFile('ready-to-send');const before=await fixture({drop_remote_responses:true});await writeFile(path.join(scratch,'send'),'send');await waitFile('unknown');
    await fixture({restart_api:true});await until(async()=>(await cloud.connection(binding)).connected);await writeFile(path.join(scratch,'recover'),'recover');
    await waitFile('finished');const result=await done;assert.equal(result.code,0,output);child=undefined;
    const after=await fixture();assert.equal(after.remote_posts-before.remote_posts,1);await until(()=>view.cards.length===1);assert.match(view.cards[0].text,/工作台 HTTPS/);
    const commands=(await stack.request(base+'/commands')).value.items;assert.equal(commands.length,3);assert.ok(commands.every(c=>c.status==='confirmed'));
    assert.equal((await page.request.get(origin+'/api/console/v1/auth/session')).status(),200);await page.getByRole('button',{name:'退出登录',exact:true}).click();await page.getByLabel('实例凭据',{exact:true}).waitFor();
    const sdk=JSON.parse(await readFile(path.join(root,'contracts/iot-sdk.lock.json'),'utf8'));
    const sources=Object.fromEntries(await fingerprints());assert.deepEqual(sources,beforeSources,'source changed during cloud journey');
    const report={passed:true,verified_at:new Date().toISOString(),sdk_revision:sdk.head,scope:'Apple 实际工作台模型经真实 HTTPS 授权、WSS 网关与 MQTT/mTLS 产品终端；浏览器及本机批准为测试驱动',real_workbench_model:true,real_https:true,browser_approval:true,untrusted_ca_rejected:true,real_wss:true,real_mysql:true,device_mtls:true,product_commands:3,lost_card_response:true,control_restart:true,original_card_posts:1,independent_logout:true,native_window:false,physical_phone:false,official_cloud:false,sources,log_sha256:hash(output)};
    await writeFile(path.join(root,'.dev/cloud-workbench-live.json'),JSON.stringify(report,null,2)+'\n');console.log('真实工作台模型云旅程通过；3条产品命令、原卡片仅1次提交、浏览器父会话独立。');
  }finally{
    if(child?.pid&&child.exitCode===null&&child.signalCode===null){const ended=new Promise(resolve=>child.once('exit',resolve));child.kill('SIGTERM');await ended}
    await fixture({});await stack?.close();await browser?.close();
  }
});

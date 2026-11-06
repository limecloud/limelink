// 隔离网关、两个不同身份的执行/IoT 设备与实际 Apple 工作台模型；批准由软件夹具驱动。
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,mkdtemp,realpath,stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify,isDeepStrictEqual} from 'node:util';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {DatabaseSync} from 'node:sqlite';

const at=process.argv.indexOf('--iot-root');
assert.ok(at>=0 && process.argv[at+1],'需要显式 --iot-root');
const codexAt=process.argv.indexOf('--agent-executable');
const native=process.argv.includes('--native-ui');
const configureAgent=process.argv.includes('--configure-agent');
assert.ok(!configureAgent||native,'配置窗口验收需要 --native-ui');
if(codexAt>=0)assert.ok(process.argv[codexAt+1]?.startsWith('/'),'需要 Agent 绝对可执行文件路径');
const root=resolve(import.meta.dirname,'..'),iot=resolve(process.argv[at+1]),exec=promisify(execFile);
const hash=data=>createHash('sha256').update(data).digest('hex');
const sdk=JSON.parse(await readFile(join(root,'contracts/iot-sdk.lock.json'),'utf8'));
assert.equal(sdk.worktree_overlay,false);
const upstreamSources={};
for(const file of ['tools/dev-stack.mjs','deploy/dev/config.json','contracts/models/lamp.json','packages/cli/src/main.mjs']){
  const actual=await readFile(join(iot,file));
  const fixed=await exec('git',['show',sdk.head+':'+file],{cwd:iot,encoding:'buffer',maxBuffer:1000000});
  assert.equal(hash(actual),hash(fixed.stdout),'测试依赖不是固定修订: '+file);upstreamSources[file]=hash(actual);
}
const {startStack,stop,until}=await import(pathToFileURL(join(iot,'tools/dev-stack.mjs')));
await mkdir(join(root,'.dev'),{recursive:true});
const directory=await mkdtemp(join(root,'.dev/agent-iot-'));
const normalize=async path=>{
  const result=await exec(process.execPath,['packages/cli/src/main.mjs','model','validate','--input',path],{cwd:iot,env:{...process.env,LIMEIOT_MODEL_VALIDATOR:process.env.LIMEIOT_MODEL_VALIDATOR??join(process.env.LIMEIOT_TEST_TARGET_DIR??join(iot,'target/debug'),'limeiot-model-validator')}});
  const report=JSON.parse(result.stdout);assert.equal(report.valid,true);return report;
};
const desktop=await normalize(join(root,'contracts/desktop.json')),lamp=await normalize(join(iot,'contracts/models/lamp.json'));
const configuration=JSON.parse(await readFile(join(iot,'deploy/dev/config.json'),'utf8'));
configuration.models=[desktop.normalized_model,lamp.normalized_model];
configuration.devices=[{device_id:'device-lamp',model_revision:desktop.model_revision},{device_id:'device-button',model_revision:lamp.model_revision}];
const gatewayConfig=join(directory,'gateway.json');await writeFile(gatewayConfig,JSON.stringify(configuration));
await exec('cargo',['build','--quiet','--locked','--manifest-path','runtime/Cargo.toml'],{cwd:root});
const stack=await startStack({directory,modelPaths:{lamp:join(root,'contracts/desktop.json'),button:join(iot,'contracts/models/lamp.json')},gatewayEnv:{LIMEIOT_CONFIG:gatewayConfig}});
const files=['contracts/desktop.json','contracts/iot-sdk.lock.json','contracts/fixtures/agent-tools.json','runtime/src/lib.rs','runtime/src/main.rs','runtime/src/agent.rs','runtime/src/agent/codex.rs','runtime/src/agent/tools.rs','runtime/tests/support/codex_fixture.py','packages/apple/Sources/LimeLinkCore/AgentClient.swift','packages/apple/Sources/LimeLinkCore/AgentIoTClient.swift','packages/apple/Sources/LimeLinkCore/AgentToolProtocol.swift','packages/apple/Sources/LimeLinkCore/LinkClient.swift','packages/apple/Sources/LimeLinkUI/WorkbenchModel.swift','packages/apple/Sources/LimeLinkUI/AgentToolsView.swift','packages/apple/AgentTests/AgentIoTLiveChecks.swift','packages/apple/AgentTests/AgentToolVectorChecks.swift','packages/apple/AgentTests/AgentChecks.swift','tools/test-agent-iot.mjs','Package.swift'];
if(native)files.push('apps/macos/DesktopAssistant.swift','apps/macos/DesktopWorkspace.swift','apps/macos/LocalTerminal.swift','apps/macos/LimeLinkApp.swift','apps/macos/DesktopAgentSettings.swift','apps/macos/DesktopSettings.swift','packages/apple/Sources/LimeLinkCore/LocalAgentConfiguration.swift','packages/apple/Sources/LimeLinkCore/CodexExecutableDiscovery.swift');
const sources=async()=>Object.fromEntries(await Promise.all(files.map(async file=>[file,hash(await readFile(join(root,file)))])));
const before=await sources();
try{
  await stop(stack.lamp);
  const workspace=join(directory,'workspace');await mkdir(workspace);
  const executable=codexAt>=0?resolve(process.argv[codexAt+1]):join(directory,'codex-fixture');
  if(codexAt<0)await writeFile(executable,await readFile(join(root,'runtime/tests/support/codex_fixture.py')),{mode:0o700});
  const config={mqtt_host:'127.0.0.1',mqtt_port:Number(stack.env.LIMEIOT_MQTT_PORT),space:'space-demo',device:'device-lamp',model_revision:desktop.model_revision,database:join(directory,'runtime.sqlite'),allow_loopback_development:true,development_password:stack.env.LIMEIOT_MQTT_PASSWORD,agent:{executable,workspaces:[{id:'work',name:'隔离工具验收',path:workspace,allow_write:false}],timeout_seconds:native?600:180,allow_iot_tools:true}};
  if(configureAgent)delete config.agent;
  const configPath=join(directory,'runtime.json');await writeFile(configPath,JSON.stringify(config),{mode:0o600});
  const commands=async()=>{
    const result=[];let cursor;
    for(let page=0;page<64;page++){
      const response=await stack.request('/api/v1/spaces/space-demo/commands'+(cursor?'?cursor='+encodeURIComponent(cursor):''));assert.equal(response.status,200);
      result.push(...response.value.items);cursor=response.value.next_cursor;if(!cursor)return result;
    }
    throw new Error('command_page_budget');
  };
  const propertyWrites=list=>list.filter(c=>c.request.device_id==='device-button'&&c.request.operation.type==='property.set');
  if(native){
    const progress=async step=>{await writeFile(join(root,'.dev/agent-iot-native-progress.json'),JSON.stringify({step,directory}));console.log(step);};
    await writeFile(join(root,'.dev/agent-iot-native-connection.json'),JSON.stringify({endpoint:stack.env.LIMEIOT_ENDPOINT,token:stack.env.LIMEIOT_TOKEN}),{mode:0o600});
    await writeFile(join(root,'.dev/agent-iot-native-finish'),'pending');
    await writeFile(join(root,'.dev/agent-iot-native-ready'),'pending');
    const binary=join(root,'.dev/artifacts/LimeLink.app/Contents/MacOS/LimeLink');
    stack.launch('native',binary,[],{LIMELINK_RUNTIME_CONFIG:configPath,LIMELINK_ENDPOINT:stack.env.LIMEIOT_ENDPOINT,LIMELINK_DEVELOPMENT:'1'});
    if(configureAgent){
      await progress('先打开设置，断开执行端，启用 Codex，选择程序和 '+workspace+'，开启设备工具，再保存并连接');
      const expectedExecutable=await realpath(executable),expectedWorkspace=await realpath(workspace);
      await until(async()=>{
        const saved=JSON.parse(await readFile(configPath,'utf8'));
        if(!saved.agent)return false;
        const {agent,...identity}=saved;
        assert.ok(isDeepStrictEqual(identity,config),'设置保存改变了设备身份或网关连接参数');
        assert.equal(agent.executable,expectedExecutable);assert.equal(agent.timeout_seconds,600);assert.equal(agent.allow_iot_tools,true);
        assert.equal(agent.workspaces.length,1);assert.equal(agent.workspaces[0].path,expectedWorkspace);assert.equal(agent.workspaces[0].allow_write,false);
        assert.equal((await stat(configPath)).mode&0o777,0o600);
        return true;
      },1800000);
    }
    const readDB=async file=>{let db;await until(()=>{try{db=new DatabaseSync(file,{readOnly:true});return true;}catch{return false;}},120000);return db;};
    const db=await readDB(join(directory,'runtime.agent.sqlite'));
    try{
      await progress('连接隔离网关，选择 space-demo 和 device-lamp，配对后读取助手配置，选择 device-button 并提交任务');
      await progress('先完成连接、配对和任务填写；就绪后向 .dev/agent-iot-native-ready 写入 ready，再提交任务');
      await until(async()=>await readFile(join(root,'.dev/agent-iot-native-ready'),'utf8')==='ready',1800000);
      await until(()=>{
        const ended=db.prepare("SELECT state,error FROM runs WHERE state IN ('expired','rejected','failed','unknown','cancelled') LIMIT 1").get();
        assert.ok(!ended,'原生任务在设备提案前结束: '+JSON.stringify(ended));
        return db.prepare("SELECT count(*) AS count FROM tool_calls WHERE tool='limeiot_command' AND state='pending'").get().count===1;
      },600000);
      assert.equal(propertyWrites(await commands()).length,0,'原生确认前出现设备写入');
      assert.equal((await stack.request('/api/v1/spaces/space-demo/devices/device-button')).value.reported['light.power'].value,false);
      await progress('设备提案已到达；请在原生助手页面核对设备、电源与目标值，点击确认操作');
      await until(()=>db.prepare("SELECT count(*) AS count FROM runs WHERE state IN ('succeeded','failed','unknown')").get().count===1,150000);
      const run=db.prepare('SELECT id,state,error FROM runs').get();assert.equal(run.state,'succeeded',run.error??'native_agent_failed');
      const all=await commands(),writes=propertyWrites(all);assert.equal(writes.length,1);assert.equal(writes[0].status,'confirmed');
      const observed=(await stack.request('/api/v1/spaces/space-demo/devices/device-button')).value.reported['light.power'].value;assert.equal(observed,true);
      const events=db.prepare("SELECT text FROM events WHERE run=? AND kind='message' ORDER BY seq").all(run.id);assert.ok(events.map(e=>e.text).join('').includes('LIMELINK_IOT_DEVICE_OK'));
      const after=await sources();assert.deepEqual(after,before,'测试中源码变化');
      const report={passed:true,verified_at:new Date().toISOString(),harness:'tools/test-agent-iot.mjs --native-ui',scope:'macOS 原生窗口提交、设备选择、本机批准、逐次设备写入确认、真实隔离 HTTP/MQTT 网关与独立模拟 IoT 设备',sdk_revision:sdk.head,sources:after,upstream_sources:upstreamSources,real_model:codexAt>=0,real_agent:codexAt>=0,fixture:codexAt<0,real_gateway:true,device_mtls:false,native_ui:true,physical_device:false,physical_phone:false,user_https_ui:false,user_http_development_ui:true,software_approval:false,approval_via_native_window:true,agent_execution:true,run_query:true,iot_grant:['device-button'],iot_tool_execution:true,no_write_before_confirmation:true,device_write_count:1,observed_property:observed,execution_and_iot_identity_separate:true,app_binary_sha256:hash(await readFile(binary)),runtime_binary_sha256:hash(await readFile(join(root,'.dev/artifacts/LimeLink.app/Contents/MacOS/limelink-runtime')))};
      report.agent_configuration_via_native_window=configureAgent;
      if(configureAgent)await writeFile(join(root,'docs/evidence/agent-settings-macos-ui.json'),JSON.stringify({...report,scope:'macOS 设置窗口启用 Codex、选择工作目录与设备工具、保存并重新连接，再完成真实 Agent 设备工具旅程',configuration_identity_preserved:true,configuration_permissions:'0600',no_json_editing:true},null,2)+'\n');
      await writeFile(join(root,'docs/evidence/agent-iot-macos-ui.json'),JSON.stringify(report,null,2)+'\n');
      await writeFile(join(root,'docs/evidence/macos-agent-ui.json'),JSON.stringify(report,null,2)+'\n');
      await progress('已通过；截图后向 .dev/agent-iot-native-finish 写入 done 关闭隔离应用');
      await until(async()=>await readFile(join(root,'.dev/agent-iot-native-finish'),'utf8')==='done',600000);
    }finally{db.close();}
    process.exitCode=0;
  }else{
  const runtime=stack.launch('runtime',join(root,'runtime/target/debug/limelink-runtime'),[configPath]);
  let view,buffer='';runtime.stdout.on('data',chunk=>{buffer+=chunk.toString();let index;while((index=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,index);buffer=buffer.slice(index+1);try{const frame=JSON.parse(line);if(frame.type==='view')view=frame;}catch{}}});
  await until(()=>view?.agent);
  const approvedPeers=new Set(),approvedRuns=new Set();
  const approve=setInterval(()=>{
    for(const peer of view?.peers??[])if(peer.state==='pending'&&!approvedPeers.has(peer.id)){approvedPeers.add(peer.id);runtime.stdin.write(JSON.stringify({type:'approve',id:peer.id})+'\n');}
    for(const run of view?.agent?.runs??[])if(run.state==='awaiting_approval'&&!approvedRuns.has(run.id)){approvedRuns.add(run.id);runtime.stdin.write(JSON.stringify({type:'agent_approve',id:run.id})+'\n');}
  },100);
  const gate=join(directory,'client-confirmation');
  let client;
  try{
    client=exec('swift',['run','-j','4','AgentChecks'],{cwd:root,env:{...process.env,LIMELINK_AGENT_IOT_ENDPOINT:stack.env.LIMEIOT_ENDPOINT,LIMELINK_AGENT_CHECK_TOKEN:stack.env.LIMEIOT_TOKEN,LIMELINK_AGENT_CHECK_REAL:codexAt>=0?'1':'0',LIMELINK_AGENT_IOT_APPROVAL_FILE:gate},timeout:230000,maxBuffer:100000});
    // 立即为进程错误安装处理，避免等待批准时产生未处理的 Promise rejection。
    let clientError;client.catch(error=>{clientError=error;});
    const deadline=Date.now()+150000;
    while(await readFile(gate,'utf8').catch(()=>null)!=='awaiting-client-confirmation'){
      if(clientError)throw clientError;
      assert.ok(Date.now()<deadline,'client_confirmation_timeout');await delay(100);
    }
    assert.equal(propertyWrites(await commands()).length,0,'用户确认前出现设备写入');
    const initial=(await stack.request('/api/v1/spaces/space-demo/devices/device-button')).value;
    assert.equal(initial.reported['light.power'].value,false);
    await writeFile(gate,'confirm');
    const result=await client;
    const check=JSON.parse(result.stdout.trim().split('\n').at(-1));assert.equal(check.passed,true);assert.equal(check.original_recovery,true);
    const all=await commands(),writes=propertyWrites(all);assert.equal(writes.length,1);assert.equal(writes[0].status,'confirmed');
    const results=all.filter(c=>{if(c.request.operation.path!=='agent.exchange')return false;const input=c.request.operation.value;if(input.kind!=='agent.tool_result')return false;return JSON.parse(input.payload).output.status==='confirmed';});
    assert.equal(results.length,1,'结果恢复产生第二次 POST');
    const final=(await stack.request('/api/v1/spaces/space-demo/devices/device-button')).value;assert.equal(final.reported['light.power'].value,true);
    const after=await sources();assert.deepEqual(after,before,'测试中源码变化');
    const report={passed:true,verified_at:new Date().toISOString(),scope:'实际 Apple 工作台模型、真实隔离 HTTP/MQTT 网关与独立模拟 IoT 设备；软件批准，执行端与模拟设备均为回环鉴权开发链路',sdk_revision:sdk.head,sources:after,upstream_sources:upstreamSources,real_model:codexAt>=0,fixture:codexAt<0,real_gateway:true,device_mtls:false,native_ui:false,physical_device:false,client:check,no_write_before_confirmation:true,device_write_count:writes.length,result_post_count:results.length,observed_property:true,execution_and_iot_identity_separate:true,runtime_binary_sha256:hash(await readFile(join(root,'runtime/target/debug/limelink-runtime')))};
    await writeFile(join(root,'docs/evidence/'+(codexAt>=0?'agent-iot-apple-live.json':'agent-iot-apple-integration.json')),JSON.stringify(report,null,2)+'\n');
    console.log(JSON.stringify({passed:true,real_model:report.real_model,device_write_count:1,result_post_count:1,native_ui:false,physical_device:false}));
  }finally{clearInterval(approve);}
  }
}finally{await stack.close();}

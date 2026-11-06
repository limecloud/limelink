// Android/.NET 共用的真实隔离网关旅程；批准由测试夹具驱动。
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,mkdtemp} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {resolve,join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';

const clientAt=process.argv.indexOf('--client');const platform=clientAt<0?'android':process.argv[clientAt+1];assert.ok(['android','dotnet'].includes(platform),'需要 android 或 dotnet 客户端');
const dotnetAt=process.argv.indexOf('--dotnet');if(platform==='dotnet')assert.ok(dotnetAt>=0&&process.argv[dotnetAt+1]?.startsWith('/'),'需要 .NET 绝对可执行文件路径');
const at=process.argv.indexOf('--iot-root');assert.ok(at>=0&&process.argv[at+1],'需要显式 --iot-root');
const codexAt=process.argv.indexOf('--agent-executable');if(codexAt>=0)assert.ok(process.argv[codexAt+1]?.startsWith('/'),'需要 Agent 绝对可执行文件路径');
const root=resolve(import.meta.dirname,'..'),iot=resolve(process.argv[at+1]),exec=promisify(execFile);
const hash=data=>createHash('sha256').update(data).digest('hex');
const sdk=JSON.parse(await readFile(join(root,'contracts/iot-sdk.lock.json'),'utf8'));assert.equal(sdk.worktree_overlay,false);
const upstreamSources={};
for(const file of ['tools/dev-stack.mjs','deploy/dev/config.json','contracts/models/lamp.json','packages/cli/src/main.mjs']){
  const actual=await readFile(join(iot,file));const fixed=await exec('git',['show',sdk.head+':'+file],{cwd:iot,encoding:'buffer',maxBuffer:1000000});
  assert.equal(hash(actual),hash(fixed.stdout),'上游测试文件不是固定修订: '+file);upstreamSources[file]=hash(actual);
}
const {startStack,stop,until}=await import(pathToFileURL(join(iot,'tools/dev-stack.mjs')));
await mkdir(join(root,'.dev'),{recursive:true});const directory=await mkdtemp(join(root,'.dev/agent-iot-'+platform+'-'));
const normalize=async file=>{const result=await exec(process.execPath,['packages/cli/src/main.mjs','model','validate','--input',file],{cwd:iot,env:{...process.env,LIMEIOT_MODEL_VALIDATOR:process.env.LIMEIOT_MODEL_VALIDATOR??join(process.env.LIMEIOT_TEST_TARGET_DIR??join(iot,'target/debug'),'limeiot-model-validator')}});const report=JSON.parse(result.stdout);assert.equal(report.valid,true);return report;};
const desktop=await normalize(join(root,'contracts/desktop.json')),lamp=await normalize(join(iot,'contracts/models/lamp.json'));
const configuration=JSON.parse(await readFile(join(iot,'deploy/dev/config.json'),'utf8'));configuration.models=[desktop.normalized_model,lamp.normalized_model];configuration.devices=[{device_id:'device-lamp',model_revision:desktop.model_revision},{device_id:'device-button',model_revision:lamp.model_revision}];
const gatewayConfig=join(directory,'gateway.json');await writeFile(gatewayConfig,JSON.stringify(configuration));
await exec('cargo',['build','--quiet','--locked','--manifest-path','runtime/Cargo.toml'],{cwd:root});
const stack=await startStack({directory,modelPaths:{lamp:join(root,'contracts/desktop.json'),button:join(iot,'contracts/models/lamp.json')},gatewayEnv:{LIMEIOT_CONFIG:gatewayConfig}});
const shared=['contracts/desktop.json','contracts/iot-sdk.lock.json','contracts/fixtures/agent-tools.json','runtime/src/lib.rs','runtime/src/main.rs','runtime/src/agent.rs','runtime/src/agent/codex.rs','runtime/src/agent/tools.rs','runtime/tests/support/codex_fixture.py','tools/test-agent-iot-clients.mjs'];
const files=[...shared,...(platform==='android'?['apps/android/core/src/main/kotlin/run/limeai/link/core/AgentClient.kt','apps/android/core/src/main/kotlin/run/limeai/link/core/AgentIoTClient.kt','apps/android/core/src/main/kotlin/run/limeai/link/core/AgentToolProtocol.kt','apps/android/core/src/main/kotlin/run/limeai/link/core/LinkClient.kt','apps/android/core/src/test/kotlin/run/limeai/link/core/AgentIoTLiveTest.kt','apps/android/core/build.gradle.kts','tools/test-agent-iot-android.mjs']:['apps/windows/LimeLink.Core/AgentClient.cs','apps/windows/LimeLink.Core/AgentIoTClient.cs','apps/windows/LimeLink.Core/AgentToolProtocol.cs','apps/windows/LimeLink.Core/LinkClient.cs','apps/windows/LimeLink.Core/LimeLink.Core.csproj','apps/windows/LimeLink.Core.Checks/AgentIoTLiveChecks.cs','apps/windows/LimeLink.Core.Checks/Program.cs','apps/windows/LimeLink.Core.Checks/LimeLink.Core.Checks.csproj'])];
const sources=async()=>Object.fromEntries(await Promise.all(files.map(async file=>[file,hash(await readFile(join(root,file)))])));
const before=await sources();
try{
  await stop(stack.lamp);const workspace=join(directory,'workspace');await mkdir(workspace);
  const executable=codexAt>=0?resolve(process.argv[codexAt+1]):join(directory,'codex-fixture');if(codexAt<0)await writeFile(executable,await readFile(join(root,'runtime/tests/support/codex_fixture.py')),{mode:0o700});
  const config={mqtt_host:'127.0.0.1',mqtt_port:Number(stack.env.LIMEIOT_MQTT_PORT),space:'space-demo',device:'device-lamp',model_revision:desktop.model_revision,database:join(directory,'runtime.sqlite'),allow_loopback_development:true,development_password:stack.env.LIMEIOT_MQTT_PASSWORD,agent:{executable,workspaces:[{id:'work',name:'隔离工具验收',path:workspace,allow_write:false}],timeout_seconds:180,allow_iot_tools:true}};
  const configPath=join(directory,'runtime.json');await writeFile(configPath,JSON.stringify(config),{mode:0o600});
  const runtime=stack.launch('runtime',join(root,'runtime/target/debug/limelink-runtime'),[configPath]);let view,buffer='';
  runtime.stdout.on('data',chunk=>{buffer+=chunk.toString();let index;while((index=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,index);buffer=buffer.slice(index+1);try{const frame=JSON.parse(line);if(frame.type==='view')view=frame;}catch{}}});await until(()=>view?.agent);
  const approvedPeers=new Set(),approvedRuns=new Set();
  const approve=setInterval(()=>{for(const peer of view?.peers??[])if(peer.state==='pending'&&!approvedPeers.has(peer.id)){approvedPeers.add(peer.id);runtime.stdin.write(JSON.stringify({type:'approve',id:peer.id})+'\n');}for(const run of view?.agent?.runs??[])if(run.state==='awaiting_approval'&&!approvedRuns.has(run.id)){approvedRuns.add(run.id);runtime.stdin.write(JSON.stringify({type:'agent_approve',id:run.id})+'\n');}},100);
  const commands=async()=>{const result=[];let cursor;for(let page=0;page<64;page++){const response=await stack.request('/api/v1/spaces/space-demo/commands'+(cursor?'?cursor='+encodeURIComponent(cursor):''));assert.equal(response.status,200);result.push(...response.value.items);cursor=response.value.next_cursor;if(!cursor)return result;}throw new Error('command_page_budget');};
  const writes=list=>list.filter(c=>c.request.device_id==='device-button'&&c.request.operation.type==='property.set');
  try{
    const gate=join(directory,'confirmation');let clientError;
    const environment={...process.env,LIMELINK_AGENT_IOT_ENDPOINT:stack.env.LIMEIOT_ENDPOINT,LIMELINK_AGENT_CHECK_TOKEN:stack.env.LIMEIOT_TOKEN,LIMELINK_AGENT_CHECK_REAL:codexAt>=0?'1':'0',LIMELINK_AGENT_IOT_APPROVAL_FILE:gate};
    const client=platform==='android'?exec('sh',['gradlew','--no-daemon',':core:test','--tests','run.limeai.link.core.AgentIoTLiveTest','--rerun-tasks'],{cwd:join(root,'apps/android'),env:environment,timeout:250000,maxBuffer:100000}):exec(process.argv[dotnetAt+1],['run','--project','apps/windows/LimeLink.Core.Checks'],{cwd:root,env:environment,timeout:250000,maxBuffer:100000});
    client.catch(error=>{clientError=error;});const deadline=Date.now()+170000;
    while(await readFile(gate,'utf8').catch(()=>null)!=='awaiting-client-confirmation'){if(clientError)throw clientError;assert.ok(Date.now()<deadline,platform+'_confirmation_timeout');await delay(100);}
    assert.equal(writes(await commands()).length,0);assert.equal((await stack.request('/api/v1/spaces/space-demo/devices/device-button')).value.reported['light.power'].value,false);await writeFile(gate,'confirm');
    const result=await client;
    if(platform==='android'){
      const xml=await readFile(join(root,'apps/android/core/build/test-results/test/TEST-run.limeai.link.core.AgentIoTLiveTest.xml'),'utf8');
      for(const [field,count]of [['tests','1'],['skipped','0'],['failures','0'],['errors','0']])assert.ok(new RegExp('\\b'+field+'="'+count+'"').test(xml),'Android 测试没有实际通过: '+field);
    }else{
      const records=result.stdout.split('\n').filter(line=>line.startsWith('{')).map(line=>JSON.parse(line));
      assert.ok(records.some(r=>r.passed===true&&r.product_client==='dotnet'&&r.original_recovery===true),'缺少实际 .NET 旅程结果');
    }
    const all=await commands(),deviceWrites=writes(all);assert.equal(deviceWrites.length,1);assert.equal(deviceWrites[0].status,'confirmed');
    const replies=all.filter(c=>c.request.operation.path==='agent.exchange'&&c.request.operation.value.kind==='agent.tool_result'&&JSON.parse(c.request.operation.value.payload).output.status==='confirmed');assert.equal(replies.length,1);
    assert.equal((await stack.request('/api/v1/spaces/space-demo/devices/device-button')).value.reported['light.power'].value,true);
    const after=await sources();assert.deepEqual(after,before,'测试中源码变化');
    const report={passed:true,verified_at:new Date().toISOString(),scope:(platform==='android'?'Android JVM':'.NET')+' 实际产品核心、真实隔离 HTTP/MQTT 网关与独立模拟 IoT 设备；软件批准，非原生窗口',product_client:platform,sdk_revision:sdk.head,sources:after,upstream_sources:upstreamSources,real_model:codexAt>=0,fixture:codexAt<0,real_gateway:true,device_mtls:false,native_ui:false,physical_device:false,workbench_model:false,no_write_before_confirmation:true,device_write_count:1,result_post_count:1,lost_device_response:true,lost_reply_response:true,original_recovery:true,scope_isolation:true,observed_property:true,execution_and_iot_identity_separate:true,log_sha256:hash(result.stdout+result.stderr),runtime_binary_sha256:hash(await readFile(join(root,'runtime/target/debug/limelink-runtime')))};
    await writeFile(join(root,'docs/evidence/'+('agent-iot-'+platform+(codexAt>=0?'-live.json':'-integration.json'))),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:true,real_model:report.real_model,device_write_count:1,result_post_count:1,native_ui:false,physical_device:false}));
  }finally{clearInterval(approve);}
}finally{await stack.close();}

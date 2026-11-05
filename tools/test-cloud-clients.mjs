import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 产品消费者的共享 HTTP 夹具；真实 Go/WSS/MQTT 验收另行运行。
const root=fileURLToPath(new URL('../',import.meta.url));
const options=process.argv.slice(2);let platform='all',dotnet=process.env.LIMELINK_DOTNET??'dotnet';
for(let i=0;i<options.length;i++){
  if(options[i]==='--platform')platform=options[++i];
  else if(options[i]==='--dotnet')dotnet=options[++i];
  else throw new Error('unsupported_cloud_check_option');
}
assert.ok(['all','apple','android','dotnet'].includes(platform));
const hash=value=>createHash('sha256').update(value).digest('hex');
const sdk=JSON.parse(await readFile(path.join(root,'contracts/iot-sdk.lock.json'),'utf8'));
assert.equal(sdk.worktree_overlay,false);
for(const file of sdk.files)assert.equal(hash(await readFile(path.join(root,'.dev/upstream',file.path))),file.sha256,'fixed SDK mismatch: '+file.path);
const inputs={
  apple:['packages/apple/Sources/LimeLinkCore/CloudLinkClient.swift','packages/apple/Sources/LimeLinkCore/SecureStore.swift','packages/apple/Tests/CloudChecks.swift','packages/apple/Tests/IdentityTests.swift','Package.swift'],
  android:['apps/android/core/src/main/kotlin/run/limeai/link/core/CloudLinkClient.kt','apps/android/core/src/main/kotlin/run/limeai/link/core/LinkClient.kt','apps/android/core/src/test/kotlin/run/limeai/link/core/CloudLinkClientTest.kt','apps/android/core/build.gradle.kts'],
  dotnet:['apps/windows/LimeLink.Core/CloudLinkClient.cs','apps/windows/LimeLink.Core/LinkClient.cs','apps/windows/LimeLink.Core.Checks/Program.cs','apps/windows/LimeLink.Core.Checks/CloudChecks.cs','apps/windows/LimeLink.Core.Checks/CloudLiveChecks.cs'],
};
async function fingerprints(target){return Promise.all(['contracts/iot-sdk.lock.json','tools/test-cloud-clients.mjs',...inputs[target]].map(async file=>({path:file,sha256:hash(await readFile(path.join(root,file)))})))}
await mkdir(path.join(root,'.dev'),{recursive:true});
const results=[];
for(const target of platform==='all'?['apple','android','dotnet']:[platform]){
  const before=await fingerprints(target);
  const token='c'.repeat(64),authorization='na-'+'b'.repeat(64),remote='remote-'+'d'.repeat(64),revision='sha256:'+'a'.repeat(64);
  const expires=new Date(Date.now()+240000).toISOString(),sessionExpires=new Date(Date.now()+3500000).toISOString();
  let origin,proof,original,remoteSpace,creates=0,queries=0,verified=0,failure;
  const server=createServer(async(request,response)=>{
    try{
      let raw='';for await(const chunk of request){raw+=chunk;assert.ok(raw.length<=16384)}
      const input=raw?JSON.parse(raw):undefined,url=new URL(request.url,origin),route=url.pathname;
      function send(body,status=200){response.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});response.end(JSON.stringify(body))}
      if(route.startsWith('/api/native/'))for(const header of ['cookie','origin','authorization'])assert.equal(request.headers[header],undefined);
      else {
        assert.equal(request.headers.origin,origin);assert.equal(request.headers.cookie,'limeiot_console='+token);
        assert.equal(request.headers['x-csrf-token'],hash('limeiot-csrf:console:'+token));
      }
      if(route==='/api/native/v1/authorizations'){
        assert.match(input.request_key,/^[a-f0-9]{64}$/);assert.equal(input.platform,{apple:'macos',android:'android',dotnet:'windows'}[target]);
        if(proof)assert.deepEqual(input,proof);else proof=input;
        return send({authorization_id:authorization,user_code:'ABCDEF12',verification_uri:origin+'/console/?native='+authorization,expires_at:expires,interval_seconds:3,status:'pending'});
      }
      if(route.endsWith('/authorizations/poll')){
        assert.equal(input.request_key,proof.request_key);assert.equal(createHash('sha256').update(input.code_verifier).digest('base64url'),proof.code_challenge);
        return send({status:'approved',expires_at:expires,material:{version:1,origin,audience:'console',session:token,principal_id:'owner',expires_at:sessionExpires}});
      }
      if(route.endsWith('/auth/session'))return send({audience:'console',principal:{principal_id:'owner',name:'夹具账号'},csrf_token:hash('limeiot-csrf:console:'+token),expires_at:sessionExpires});
      if(route.endsWith('/gateways'))return send({gateways:[{gateway_id:'gateway-a',space_id:route.split('/')[5],local_space_id:'local-space',principal_id:'owner',scopes:['devices.read','commands.write'],revision:'binding-a',active:true}]});
      if(route.endsWith('/devices'))return send({items:[{device_id:'desktop',model_revision:revision,ready:true,reported:{}}],next:null,binding_revision:'binding-a'});
      if(route.includes('/model-releases/'))return send({revision,model:{model_id:'urn:limelink:model:desktop:1',services:[]}});
      if(route.endsWith('/remote-commands')&&request.method==='POST'){
        creates++;assert.equal(creates,1);assert.equal(input.gateway_id,'gateway-a');assert.equal(input.binding_revision,'binding-a');assert.equal(input.device_id,'desktop');assert.equal(input.model_revision,revision);
        assert.equal(input.operation.type,'action.invoke');assert.equal(input.operation.path,'link.exchange');assert.match(input.request_key,/^[a-f0-9]{64}$/);
        const exchange=input.operation.value;
        const key=createPublicKey({key:Buffer.from('3059301306072a8648ce3d020106082a8648ce3d030107034200'+exchange.public_key,'hex'),format:'der',type:'spki'});
        const message=space=>['limelink.exchange/v1',space,'desktop',revision,exchange.client_id,exchange.kind,exchange.nonce,String(exchange.expires_at),hash(exchange.payload)].join('\n');
        assert.equal(verify('sha256',Buffer.from(message('local-space')),key,Buffer.from(exchange.signature,'hex')),true);
        assert.equal(verify('sha256',Buffer.from(message('cloud-space')),key,Buffer.from(exchange.signature,'hex')),false);verified++;
        original=input;remoteSpace=route.split('/')[5];request.socket.destroy();return;
      }
      if(route.includes('/remote-commands/by-key/')){
        queries++;assert.ok(original);assert.equal(route.split('/').at(-1),original.request_key);assert.equal(route.split('/')[5],remoteSpace);
        if(queries===1)return send({error:{code:'not_found'}},404);
        return send({remote_id:remote,space_id:remoteSpace,principal_id:'owner',local_space_id:'local-space',request_digest:'e'.repeat(64),request:original,status:'unknown',local_result:null});
      }
      throw new Error('unexpected_fixture_route');
    }catch(error){failure??=error;response.writeHead(500,{'Content-Type':'application/json'});response.end('{"error":{"code":"fixture_contract_failed"}}')}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
  const env={...process.env,LIMELINK_CLOUD_CHECK_ORIGIN:origin};
  const command=target==='apple'?'swift':target==='android'?'sh':dotnet;
  const args=target==='apple'?['run','LinkChecks']:target==='android'?['gradlew','--no-daemon',':core:test','--tests','run.limeai.link.core.CloudLinkClientTest','--rerun-tasks']:['run','--project','apps/windows/LimeLink.Core.Checks'];
  const cwd=target==='android'?path.join(root,'apps/android'):root;
  try{
    const child=spawn(command,args,{cwd,env,stdio:['ignore','pipe','pipe']});let output='';
    child.stdout.on('data',chunk=>output+=chunk);child.stderr.on('data',chunk=>output+=chunk);
    let timer;const done=new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(new Error(target+' consumer failed: '+output)));timer=setTimeout(()=>{child.kill('SIGTERM');reject(new Error(target+' consumer timeout'))},120000)});
    try{await done}finally{clearTimeout(timer)}
    if(failure)throw failure;
    assert.equal(creates,1);assert.equal(queries,2);assert.equal(verified,1);
    const sources=await fingerprints(target);assert.deepEqual(sources,before,'consumer source changed during checks');
    const result={target,passed:true,cloud_fixture:true,posts:creates,original_queries:queries,local_space_signature:true,hardware:false,native_app:false,sources,log_sha256:hash(output)};
    results.push(result);
    await writeFile(path.join(root,'.dev','cloud-clients-'+target+'.json'),JSON.stringify({passed:true,sdk_revision:sdk.head,fixture:true,official_cloud:false,native_app:false,hardware:false,results:[result]},null,2)+'\n');
    console.log(target+'：本地空间签名、跨空间阻塞、原键404不重发与客户端重建通过。');
  }finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve))}
}
const sources={};
for(const result of results)for(const file of result.sources){if(file.path in sources)assert.equal(sources[file.path],file.sha256);sources[file.path]=file.sha256}
const report={passed:true,sdk_revision:sdk.head,fixture:true,official_cloud:false,native_app:false,hardware:false,results,sources};
await writeFile(path.join(root,'.dev','cloud-clients-'+platform+'.json'),JSON.stringify(report,null,2)+'\n');

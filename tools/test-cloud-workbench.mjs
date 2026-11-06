import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,mkdtemp,cp} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import path from 'node:path';

// 显式消费固定上游源码；复用其临时 MySQL / HTTPS 控制面入口，不访问用户实例。
const root=path.resolve(import.meta.dirname,'..');
const at=process.argv.indexOf('--iot-root');assert.equal(process.argv.length,4);assert.equal(at,2);
const iot=path.resolve(process.argv[at+1]);
const sdk=JSON.parse(await readFile(path.join(root,'contracts/iot-sdk.lock.json'),'utf8'));assert.equal(sdk.worktree_overlay,false);
const hash=data=>createHash('sha256').update(data).digest('hex');
for(const file of sdk.files){
  assert.equal(hash(await readFile(path.join(iot,file.path))),file.sha256,'upstream SDK differs: '+file.path);
  assert.equal(hash(await readFile(path.join(root,'.dev/upstream',file.path))),file.sha256,'consumed SDK differs: '+file.path);
}
await mkdir(path.join(root,'.dev'),{recursive:true});
const directory=await mkdtemp(path.join(root,'.dev/cloud-workbench-'));
await mkdir(path.join(directory,'www/console'),{recursive:true});
await cp(path.join(iot,'apps/console/dist'),path.join(directory,'www/console'),{recursive:true});
await readFile(path.join(directory,'www/console/index.html'));
const env={...process.env,LIMELINK_TEST_IOT_ROOT:iot,LIMELINK_TEST_CLOUD_DIRECTORY:directory,LIMEIOT_TEST_CONSUMER_WEB_DIR:path.join(directory,'www'),LIMEIOT_TEST_CONSUMER_SUITE:path.join(root,'tools/cloud-workbench.test.mjs')};
const code=await new Promise((resolve,reject)=>{
  const child=spawn(process.execPath,[path.join(iot,'tools/test-control.mjs'),'--consumer-web'],{cwd:iot,env,stdio:'inherit'});
  child.once('error',reject);child.once('exit',resolve);
});
const reportPath=path.join(root,'.dev/cloud-workbench-live.json');
if(code!==0){await writeFile(reportPath,JSON.stringify({passed:false,exit_code:code,sdk_revision:sdk.head,hardware:false})+'\n');process.exitCode=1;}
else console.log('工作台模型的真实 HTTPS / WSS / MQTT/mTLS 产品云旅程通过。');

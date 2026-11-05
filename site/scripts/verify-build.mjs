import {readdir,readFile,stat} from 'node:fs/promises';
import {resolve,join,relative} from 'node:path';

const root=resolve('dist');
const files=[];
async function walk(folder){for(const entry of await readdir(folder,{withFileTypes:true})){const path=join(folder,entry.name);if(entry.isDirectory())await walk(path);else files.push(path);}}
await walk(root);
const errors=[];
let links=0;
for(const file of files.filter(path=>path.endsWith('.html'))){
  const html=await readFile(file,'utf8');
  for(const [,target] of html.matchAll(/\b(?:href|src)="([^"]+)"/g)){
    if(/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(target))continue;
    const url=new URL(target,'https://link.limeai.run/'+relative(root,file));
    let destination=resolve(root,'.'+decodeURIComponent(url.pathname));
    if(!destination.startsWith(root+'/')&&destination!==root){errors.push('链接越界: '+target);continue;}
    try{if((await stat(destination)).isDirectory())destination=join(destination,'index.html');await stat(destination);}
    catch{errors.push(relative(root,file)+' -> '+target);continue;}
    if(url.hash&&destination.endsWith('.html')){
      const content=await readFile(destination,'utf8');
      const fragment=decodeURIComponent(url.hash.slice(1));
      if(!content.includes('id="'+fragment+'"'))errors.push('锚点不存在: '+relative(root,file)+' -> '+target);
    }
    links++;
  }
}
const gallery=await readFile(join(root,'scenes/index.html'),'utf8');
if((gallery.match(/class="gallery-card"/g)||[]).length!==28)errors.push('图册必须覆盖全部 28 张生成图');
const manifest=JSON.parse(await readFile(join(root,'scene-manifest.json'),'utf8'));
if(manifest.length!==28)errors.push('图像清单不完整');
for(const file of files.filter(path=>/\.(html|json|js|css|md|txt|yml)$/.test(path))){
  const content=await readFile(file,'utf8');
  if(/sk-[A-Za-z0-9]{24,}|-----BEGIN (?:RSA |EC )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}/.test(content))errors.push('制品发现疑似密钥: '+relative(root,file));
  if(/\/Users\/|file:\/\//.test(content))errors.push('制品发现本机路径: '+relative(root,file));
}
console.log(JSON.stringify({html_pages:files.filter(path=>path.endsWith('.html')).length,local_links:links,scene_images:manifest.length,errors},null,2));
if(errors.length)process.exitCode=1;

import { readdirSync, readFileSync } from 'node:fs';
import { posix, resolve } from 'node:path';
import { Marked } from 'marked';

const root=resolve('../docs')+'/';
export function slugFor(path:string):string {
  return path.replace(/(^|\/)README\.md$/, '').replace(/\.md$/,'').replace(/\/$/,'');
}
export function documents(){
  return readdirSync(root,{recursive:true}).map(String).filter(path=>path.endsWith('.md')).sort().map(path=>{
    const raw=readFileSync(root+path,'utf8');
    return {path,slug:slugFor(path),title:raw.split('\n')[0].replace(/^#\s*/,''),raw};
  });
}
export function resourceLink(target:string,source:string):string{
  if(/^(?:[a-z][a-z0-9+.-]*:|\/\/|#|\/)/i.test(target))return target;
  const match=target.match(/^([^?#]*)(.*)$/);
  const path=posix.normalize(posix.join('docs',posix.dirname(source),decodeURIComponent(match?.[1]??'')));
  if(path.startsWith('docs/')&&path.endsWith('.md')){
    const slug=slugFor(path.slice(5));
    return '/docs/'+(slug?slug+'/':'')+(match?.[2]??'');
  }
  return '/resources/'+path+(match?.[2]??'');
}
export async function renderDoc(raw:string,source:string){
  const counts=new Map<string,number>();
  const parser=new Marked();
  parser.use({renderer:{heading({tokens,depth,text}){
    const base=text.toLowerCase().replace(/[^\p{L}\p{N}_\- ]/gu,'').replace(/ /g,'-');
    const number=counts.get(base)??0;counts.set(base,number+1);
    const id=base+(number?'-'+number:'');
    return '<h'+depth+' id="'+id+'">'+this.parser.parseInline(tokens)+'</h'+depth+'>\n';
  }}});
  const html=await parser.parse(raw);
  return html.replace(/\b(href|src)="([^"]+)"/g,(_,attribute,target)=>attribute+'="'+resourceLink(target,source)+'"');
}

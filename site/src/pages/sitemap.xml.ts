import {documents} from '../lib/docs';
export function GET(){
  const paths=['/','/scenes/','/brand/','/privacy/',...documents().map(doc=>'/docs/'+(doc.slug?doc.slug+'/':''))];
  const xml='<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'+paths.map(path=>'<url><loc>https://link.limeai.run'+path+'</loc></url>').join('')+'</urlset>';
  return new Response(xml,{headers:{'Content-Type':'application/xml; charset=utf-8'}});
}

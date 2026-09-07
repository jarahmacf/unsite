import {publicRead} from "@/lib/production/public-delivery";
import {publicRuntime} from "@/lib/production/supabase";
export const dynamic="force-dynamic";
export async function GET(_request:Request,{params}:{params:Promise<{page:string}>}){
  const {page}=await params;if(!/^\d{1,6}\.xml$/.test(page))return new Response(null,{status:404});
  try{
    const index=Number(page.replace(".xml","")),data=await publicRead<{items:{path:string;published_at:string}[];total:number}>(`/sitemap?offset=${index*5000}&limit=5000`),origin=publicRuntime().origin;
    if(index>0&&index*5000>=data.total)return new Response(null,{status:404});
    const esc=(s:string)=>s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/"/g,"&quot;");
    const entries=data.items.map(p=>`<url><loc>${esc(origin+p.path)}</loc><lastmod>${new Date(p.published_at).toISOString()}</lastmod></url>`).join("");
    return new Response(`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${index===0?`<url><loc>${esc(origin+"/directory")}</loc></url>`:""}${entries}</urlset>`,{headers:{"Content-Type":"application/xml","Cache-Control":"no-store"}});
  }catch{return new Response("Sitemap temporarily unavailable",{status:503,headers:{"Retry-After":"60"}});}
}

import {publicRead} from "@/lib/production/public-delivery";
import {publicRuntime} from "@/lib/production/supabase";
export const dynamic="force-dynamic";
export async function GET(){
  try{const {total}=await publicRead<{total:number}>("/sitemap?limit=1"),origin=publicRuntime().origin;
    const body=Array.from({length:Math.max(1,Math.ceil(total/5000))},(_,i)=>`<sitemap><loc>${origin}/sitemaps/${i}.xml</loc></sitemap>`).join("");
    return new Response(`<?xml version="1.0" encoding="UTF-8"?><sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${body}</sitemapindex>`,{headers:{"Content-Type":"application/xml","Cache-Control":"no-store"}});
  }catch{return new Response("Sitemap temporarily unavailable",{status:503,headers:{"Retry-After":"60"}});}
}

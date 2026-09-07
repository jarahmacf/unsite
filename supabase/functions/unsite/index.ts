import { createHandler } from "./api.ts";
declare const Deno: { env:{get(name:string):string|undefined}; serve(handler:(request:Request)=>Promise<Response>):void };
const modern=JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
const key=modern.default || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const url=Deno.env.get("SUPABASE_URL");
if(!key || !url)throw new Error("Supabase runtime credentials are unavailable");
Deno.serve(createHandler({url,key,indexed:true,embeddingKey:Deno.env.get("OPENAI_API_KEY")||"",publicOrigin:Deno.env.get("UNSITE_PUBLIC_ORIGIN")||"https://unsite.vercel.app"}));

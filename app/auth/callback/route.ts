export const dynamic="force-dynamic";
import {requestClient} from "@/lib/production/supabase";
export async function GET(request:Request){
  const context=requestClient(request),url=new URL(request.url),code=url.searchParams.get("code");
  let destination="/?auth_error=confirmation";
  if(code){const {error}=await context.supabase.auth.exchangeCodeForSession(code);if(!error)destination=url.searchParams.get("next")==="/account/recover"?"/account/recover":"/";}
  context.headers.set("Location",new URL(destination,context.config.origin||url.origin).href);
  return new Response(null,{status:303,headers:context.headers});
}

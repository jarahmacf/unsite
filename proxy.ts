import {NextResponse,type NextRequest} from "next/server";
import {publicRuntime} from "./lib/production/supabase";
import {routeHostname,normalizedHost,platformHost} from "./lib/production/host-routing";
export async function proxy(request:NextRequest){
  try{
    const host=normalizedHost(request.headers.get("host")||new URL(request.url).host);
    if(host&&platformHost(host,"https://unsite.vercel.app"))return NextResponse.next();
    const result=await routeHostname(request,publicRuntime());
    if(!result)return NextResponse.next();
    if(result instanceof Response)return result;
    return NextResponse.rewrite(new URL(result.rewrite,request.url));
  }catch{return new NextResponse("Public hostname routing is temporarily unavailable",{status:503,headers:{"Cache-Control":"no-store"}});}
}
export const config={matcher:["/((?!_next/|fonts/|favicon.ico).*)"]};

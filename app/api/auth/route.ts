export const dynamic="force-dynamic";
import {z} from "zod";
import {apiError,AppError,readJson,requestClient,writeGuard} from "@/lib/production/supabase";
const email=z.string().trim().email().max(254);
export async function GET(request:Request){
  let context;
  try{context=requestClient(request);const {data}=await context.supabase.auth.getUser();return Response.json({user:data.user?{id:data.user.id,email:data.user.email}:null},{headers:context.headers});}
  catch(e){return apiError(e,context?.headers);}
}
export async function POST(request:Request){
  let context;
  try{
    writeGuard(request);context=requestClient(request);
    const raw=await readJson(request),action=z.enum(["signin","signup","signout","recovery","password","resend"]).parse(raw.action);
    const client=context.supabase;
    if(action==="signout"){
      const {error}=await client.auth.signOut({scope:"local"});if(error)throw new AppError(503,"Sign out didn’t complete. Please try again.");
    }else if(action==="signup"){
      const input=z.object({email,password:z.string().min(12,"Use at least 12 characters.").max(128)}).parse(raw);
      const {data,error}=await client.auth.signUp({...input,options:{emailRedirectTo:context.config.origin+"/auth/callback"}});
      if(error)throw new AppError(400,error.code==="over_email_send_rate_limit"?"Email sending is temporarily limited. Please try again later.":"Account creation didn’t complete. Check your details and try again.");
      return Response.json({ok:true,confirmationRequired:!data.session},{headers:context.headers});
    }else if(action==="signin"){
      const input=z.object({email,password:z.string().min(1).max(128)}).parse(raw);
      const {error}=await client.auth.signInWithPassword(input);
      if(error)throw new AppError(401,error.code==="email_not_confirmed"?"Confirm your email before signing in.":"That email and password combination wasn’t recognized.");
    }else if(action==="resend"){
      const {error}=await client.auth.resend({type:"signup",email:email.parse(raw.email),options:{emailRedirectTo:context.config.origin+"/auth/callback"}});
      if(error)throw new AppError(400,"The confirmation email could not be sent. Please try again later.");
    }else if(action==="recovery"){
      const {error}=await client.auth.resetPasswordForEmail(email.parse(raw.email),{redirectTo:context.config.origin+"/auth/callback?next=/account/recover"});
      if(error)throw new AppError(400,"The reset email could not be sent. Please try again later.");
    }else{
      const {data}=await client.auth.getUser();if(!data.user)throw new AppError(401,"Open your password reset link first.");
      const password=z.string().min(12,"Use at least 12 characters.").max(128).parse(raw.password);
      const {error}=await client.auth.updateUser({password});if(error)throw new AppError(400,"The password could not be updated.");
    }
    return Response.json({ok:true},{headers:context.headers});
  }catch(e){return apiError(e,context?.headers);}
}

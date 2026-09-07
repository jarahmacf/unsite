export const dynamic="force-dynamic";
import {z} from "zod";
import {invitationReturnPath} from "@/lib/production/invitations";
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
    const raw=await readJson(request),action=z.enum(["signin","signup","signout","recovery","password","resend","change_password","signout_others"]).parse(raw.action);
    const client=context.supabase;
    const returnPath=invitationReturnPath(raw.return_to);
    const confirmationUrl=context.config.origin+"/auth/callback"+(returnPath!=="/"?"?next="+encodeURIComponent(returnPath):"");
    if(action==="signout"){
      const {error}=await client.auth.signOut({scope:"local"});if(error)throw new AppError(503,"Sign out didn’t complete. Please try again.");
    }else if(action==="signout_others"){
      const {data}=await client.auth.getUser();if(!data.user)throw new AppError(401,"Sign in to manage your account.");
      const {error}=await client.auth.signOut({scope:"others"});if(error)throw new AppError(503,"Other sessions could not be signed out. Try again.");
    }else if(action==="change_password"){
      const input=z.object({current_password:z.string().min(1).max(128),password:z.string().min(12,"Use at least 12 characters.").max(128)}).parse(raw);
      const {data}=await client.auth.getUser();if(!data.user?.email)throw new AppError(401,"Sign in to manage your account.");
      const check=await client.auth.signInWithPassword({email:data.user.email,password:input.current_password});
      if(check.error)throw new AppError(401,"Your current password wasn’t recognized.");
      const {error}=await client.auth.updateUser({password:input.password});if(error)throw new AppError(400,"The password could not be updated. Choose a different password and try again.");
    }else if(action==="signup"){
      const input=z.object({email,password:z.string().min(12,"Use at least 12 characters.").max(128)}).parse(raw);
      const {data,error}=await client.auth.signUp({...input,options:{emailRedirectTo:confirmationUrl}});
      if(error)throw new AppError(400,error.code==="over_email_send_rate_limit"?"Email sending is temporarily limited. Please try again later.":"Account creation didn’t complete. Check your details and try again.");
      return Response.json({ok:true,confirmationRequired:!data.session},{headers:context.headers});
    }else if(action==="signin"){
      const input=z.object({email,password:z.string().min(1).max(128)}).parse(raw);
      const {error}=await client.auth.signInWithPassword(input);
      if(error)throw new AppError(401,error.code==="email_not_confirmed"?"Confirm your email before signing in.":"That email and password combination wasn’t recognized.");
    }else if(action==="resend"){
      const {error}=await client.auth.resend({type:"signup",email:email.parse(raw.email),options:{emailRedirectTo:confirmationUrl}});
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

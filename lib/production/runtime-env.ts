import "server-only";
const publicUrl=process.env.UNSITE_SUPABASE_URL || process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || "https://taikoetkfginjymihxpf.supabase.co";
export const env={
  UNSITE_SUPABASE_URL:process.env.UNSITE_SUPABASE_URL || process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || "https://taikoetkfginjymihxpf.supabase.co",
  UNSITE_SUPABASE_PUBLISHABLE_KEY:process.env.UNSITE_SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_PUBLISHABLE_KEY || process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || (publicUrl.replace(/\/$/, "") === "https://taikoetkfginjymihxpf.supabase.co" ? "sb_publishable_M1WFH4TeJ-vV7T8D8T9CFw_NWQ7mxmM" : undefined),
  UNSITE_APP_ORIGIN:process.env.UNSITE_APP_ORIGIN || "https://unsite.vercel.app",
  UNSITE_PUBLIC_ORIGIN:process.env.UNSITE_PUBLIC_ORIGIN || "https://unsite.vercel.app",
  UNSITE_WORKER_TOKEN:process.env.UNSITE_WORKER_TOKEN,
  UNSITE_WORKER_GATEWAY_KEY:process.env.UNSITE_WORKER_GATEWAY_KEY,
};

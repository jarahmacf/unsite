import type {MetadataRoute} from "next";
import {publicRuntime} from "@/lib/production/supabase";
export const dynamic="force-dynamic";
export default function robots():MetadataRoute.Robots{return {rules:[{userAgent:"*",allow:["/p/","/directory"],disallow:["/api/","/account/","/auth/","/demo"]}],sitemap:publicRuntime().origin+"/sitemap.xml"};}

import {z} from "zod";
import type {Snapshot} from "./release";
import type {DeliveryReport} from "./delivery-check";
import type {Publisher} from "./public-types";
export type {Publisher,PublicResource} from "./public-types";
import type {PublicResource} from "./public-types";

export const entityTypes=["Organization","Person","CreativeWork","Thing"] as const;
export function publicHttps(value:string){
  try{const u=new URL(value);return u.protocol==="https:"&&!u.username&&!u.password&&!u.port&&!!u.hostname.includes(".")&&!/^(localhost|127\.|0\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/.test(u.hostname)&&!/[\[\]:]/.test(u.hostname)&&!/(\.localhost|\.local|\.internal)$/.test(u.hostname);}
  catch{return false;}
}
export function domainName(value:string){
  const url=new URL(value.includes("://")?value:"https://"+value);
  if(!publicHttps(url.href)||url.pathname!=="/"||url.search||url.hash)throw new Error("Enter a public domain without a path, port, or credentials.");
  return url.hostname.toLowerCase().replace(/\.$/,"");
}
export const httpsUrl=z.string().trim().max(2000).refine(publicHttps,"Use a public HTTPS URL without credentials or a custom port.").transform(v=>new URL(v).href);
const id=z.string().uuid(),names=z.array(z.string().trim().min(1).max(100)).max(20);
export const presenceCommands={
  save_semantic:z.object({space_id:id,revision:z.number().int().min(0),enabled:z.boolean(),daily_query_limit:z.number().int().min(1).max(1000),consent:z.literal("openai-public-embeddings-v1").optional()}),
  index_release:z.object({space_id:id,release_id:id,request_id:id,consent:z.literal("openai-public-embeddings-v1"),retry_acknowledged:z.boolean().optional()}),
  register_host:z.object({space_id:id,claim_id:id,revision:z.number().int().min(0)}),
  check_host:z.object({space_id:id}),
  disable_host:z.object({space_id:id}),
  save_discovery:z.object({space_id:id,revision:z.number().int().min(0),google_token:z.string().regex(/^[a-zA-Z0-9_-]{0,200}$/),bing_token:z.string().regex(/^[a-zA-Z0-9_-]{0,200}$/),indexnow_enabled:z.boolean(),consent:z.literal("indexnow-public-urls-v1").optional()}),
  submit_discovery:z.object({space_id:id}),
  check_resources:z.object({space_id:id}),
  save_publisher:z.object({space_id:id,revision:z.number().int().min(0),entity_type:z.enum(entityTypes),official_url:z.union([z.literal(""),httpsUrl]),aliases:names,profile_urls:z.array(httpsUrl).max(12)}),
  claim_domain:z.object({space_id:id,domain:z.string().trim().max(253).transform((v,ctx)=>{try{return domainName(v);}catch{ctx.addIssue({code:z.ZodIssueCode.custom,message:"Enter a public domain without a path, port, or credentials."});return z.NEVER;}}),request_id:id}),
  check_domain:z.object({space_id:id,claim_id:id}),
  revoke_domain:z.object({space_id:id,claim_id:id}),
  save_resource:z.object({space_id:id,id:id,revision:z.number().int().min(0),title:z.string().trim().min(1).max(200),description:z.string().trim().max(2000),url:httpsUrl,mime_type:z.string().trim().regex(/^[\w.+-]+\/[\w.+-]+$/).max(100),version_label:z.string().trim().max(100),as_of:z.string().date().nullable(),active:z.boolean()}),
  save_monitor:z.object({space_id:id,source_id:id,cadence:z.enum(["off","daily","weekly"])}),
  check_source:z.object({space_id:id,source_id:id}),
  check_delivery:z.object({space_id:id,request_id:id}),
  save_observation:z.object({space_id:id,request_id:id,question:z.string().trim().min(2).max(1000),platform:z.string().trim().min(1).max(100),mode:z.enum(["web","http","mcp"]),observed_at:z.string().datetime(),cited_urls:z.array(httpsUrl).max(20),preferred_source:z.boolean().nullable(),correct:z.boolean().nullable(),stale_answer:z.boolean().nullable().optional(),notes:z.string().trim().max(4000),evidence_url:z.union([z.literal(""),httpsUrl])}),
  delete_observation:z.object({space_id:id,observation_id:id}),
};
export const presenceActions=Object.keys(presenceCommands);
export type DomainClaim={id:string;domain:string;challenge:string;status:"pending"|"verified"|"revoked";checked_at:string|null;verified_at:string|null;expires_at:string|null;error_message:string|null;next_check_at:string|null};
export type SourceMonitor={source_id:string;cadence:"off"|"daily"|"weekly";last_checked_at:string|null;last_changed_at:string|null;next_check_at:string|null;error_message:string|null;failures:number};
export type SourceChange={id:string;source_id:string;old_version_id:string|null;new_version_id:string;created_at:string;affected_record_ids:string[]};
export type VisibilityObservation={id:string;question:string;platform:string;mode:"web"|"http"|"mcp";observed_at:string;cited_urls:string[];preferred_source:boolean|null;correct:boolean|null;stale_answer?:boolean|null;notes:string;evidence_url:string};
export type DeliveryCheckRun={id:string;status:"queued"|"running"|"completed"|"failed";release_id:string;created_at:string;result:DeliveryReport|null;index_results?:{question:string;passed:boolean;returned_ids:string[]}[];error_message:string|null};
export type SemanticState={settings:{enabled:boolean;daily_query_limit:number;revision:number;query_requests:number;usage_day?:string};indexes:{release_id:string;model:string;dimensions:number;authorized_at:string;input_characters:number;total_chunks:number;ready_chunks:number;blocked_chunks:number;pending_chunks:number;error_message:string|null;provider_tokens:number}[]};
export type HostingState={id:string;hostname:string;claim_id:string;status:"pending"|"active"|"disabled";checked_at:string|null;expires_at:string|null;error_message:string|null;revision:number;proof_valid:boolean};
export type DiscoveryState={google_token:string;bing_token:string;indexnow_enabled:boolean;revision:number};
export type ResourceCheck={id:string;release_id:string;resource_id:string;title:string;url:string;status:string;checked_at:string|null;next_at:string|null;error_message:string|null;result:{ok:boolean;http_status?:number;content_type?:string;warning?:string|null;final_url?:string}|null};
export type SearchSubmission={id:string;release_id:string|null;status:string;created_at:string;checked_at:string|null;next_at:string|null;error_message:string|null;result:{ok:boolean;http_status:number;url_count:number;state:string;indexed:null}|null};
export type PresenceState={publisher:Publisher;claims:DomainClaim[];resources:PublicResource[];monitors:SourceMonitor[];changes:SourceChange[];observations:VisibilityObservation[];delivery_checks?:DeliveryCheckRun[];semantic?:SemanticState;hosting?:HostingState|null;discovery?:DiscoveryState;resource_checks?:ResourceCheck[];submissions?:SearchSubmission[]};
export function hostingReady(h:HostingState|null|undefined,now=Date.now()){return Boolean(h&&h.status==="active"&&h.proof_valid&&h.expires_at&&Date.parse(h.expires_at)>now);}
export type Authority={domain:string;method:"dns_txt";status:"verified"|"unverified";checked_at:string|null;expires_at:string|null;scope:"domain_control"};
export const emptyPublisher=():Publisher=>({entity_type:"Thing",official_url:"",aliases:[],profile_urls:[],revision:0});
export function claimState(c:DomainClaim,now=Date.now()){return c.status==="verified"&&(!c.expires_at||Date.parse(c.expires_at)<=now)?"expired":c.status;}
export function ownershipRecord(spaceId:string,claim:Pick<DomainClaim,"domain"|"challenge">){return {name:"_unsite."+claim.domain,type:"TXT",value:"unsite="+spaceId+"."+claim.challenge};}
export function entityMetadata(snapshot:Snapshot,canonical:string){
  const p=snapshot.publisher||emptyPublisher();
  return {"@context":"https://schema.org","@type":p.entity_type,"@id":canonical+"#entity",url:canonical,name:snapshot.name,description:snapshot.description,...(p.aliases.length?{alternateName:p.aliases}:{}),...(p.official_url||p.profile_urls.length?{sameAs:[...new Set([p.official_url,...p.profile_urls].filter(Boolean))]}:{})};
}
export function visibilitySummary(items:VisibilityObservation[],publicationUrls:string[]){
  const web=items.filter(i=>i.mode==="web"),known=web.filter(i=>i.preferred_source!==null),reviewed=web.filter(i=>i.correct!==null);
  const citesPublication=(value:string)=>{try{const u=new URL(value);return publicationUrls.some(base=>{const b=new URL(base);return u.origin===b.origin&&(u.pathname===b.pathname||u.pathname.startsWith(b.pathname.replace(/\/$/,"")+"/"));});}catch{return false;}};
  return {observations:web.length,cited:web.filter(i=>i.cited_urls.some(citesPublication)).length,preferred:known.filter(i=>i.preferred_source).length,preference_reviewed:known.length,correct:reviewed.filter(i=>i.correct).length,accuracy_reviewed:reviewed.length,stale:web.filter(i=>i.stale_answer===true).length,staleness_reviewed:web.filter(i=>typeof i.stale_answer==="boolean").length};
}

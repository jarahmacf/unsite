import { z } from "zod";
import {COLLECTION_DISCLOSURE_VERSION} from "./collection";
import {AI_DISCLOSURE_VERSION} from "./ai-consent";
import {RELATIONS,KNOWLEDGE_STATES,FRAMINGS,validContext} from "./knowledge";
const uuid=z.string().uuid();
const name=z.string().trim().min(1).max(200);
const fields=z.record(z.union([z.string().max(4000),z.number().finite(),z.boolean(),z.null()])).refine(v=>Object.keys(v).length<=30,"Too many fields");
const context=z.object({summary:z.string().trim().max(1200),aliases:z.array(z.string().trim().min(1).max(100)).max(20),topics:z.array(z.string().trim().min(1).max(100)).max(20),status:z.enum(KNOWLEDGE_STATES),as_of:z.string().nullable(),type_label:z.string().trim().max(100).optional(),framing:z.enum(FRAMINGS).optional(),attribution:z.string().trim().max(600).optional()}).strict().refine(validContext,"Use a valid context date and labels.").optional();
const links=z.array(z.object({target_id:uuid,relation:z.enum(RELATIONS)})).max(30).optional();
export const recordKind=z.enum(["about","person","offering","project","faq","policy","location","general"]);
export const sourceInput=z.object({space_id:uuid,title:name,kind:z.enum(["file","text","url"]),mime_type:z.string().max(120).default("text/plain"),byte_size:z.number().int().min(0).max(20*1024*1024).default(0),text_content:z.string().max(200000).optional(),origin_url:z.string().url().max(2000).optional(),request_id:uuid,source_id:uuid.optional()}).superRefine((v,c)=>{
  if(v.kind==="text"&&!v.text_content?.trim())c.addIssue({code:"custom",message:"Add some text to import."});
  if(v.kind==="url"&&(!v.origin_url||!v.origin_url.startsWith("https://")))c.addIssue({code:"custom",message:"Use a public HTTPS URL."});
  if(v.kind==="file"&&!['text/plain','text/markdown','application/json','application/pdf'].includes(v.mime_type))c.addIssue({code:"custom",message:"Use a PDF, text, Markdown, or JSON file."});
});
export const commandSchemas={
  restore_source:z.object({space_id:uuid,source_id:uuid}),
  create_invitation:z.object({space_id:uuid,email:z.string().trim().email().max(254),role:z.enum(["editor","viewer"]),token:z.string().regex(/^[0-9a-f]{64}$/),request_id:uuid}),
  accept_invitation:z.object({invitation_id:uuid,token:z.string().regex(/^[0-9a-f]{64}$/)}),
  revoke_invitation:z.object({space_id:uuid,invitation_id:uuid}),
  update_member:z.object({space_id:uuid,user_id:uuid,role:z.enum(["editor","viewer"])}),
  remove_member:z.object({space_id:uuid,user_id:uuid}),
  leave_workspace:z.object({space_id:uuid}),
  start_collection_run:z.object({space_id:uuid,goal:z.string().trim().min(1).max(1500),version_ids:z.array(uuid).min(1).max(8).refine(v=>new Set(v).size===v.length,"Select each version once"),max_requests:z.number().int().min(1).max(200),approved:z.literal(true),disclosure_version:z.literal(COLLECTION_DISCLOSURE_VERSION),request_id:uuid}),
  cancel_collection_run:z.object({space_id:uuid,run_id:uuid}),
  resume_collection_run:z.object({space_id:uuid,run_id:uuid,max_requests:z.number().int().min(1).max(200),retry_reviewed:z.literal(true)}),
  save_retrieval_case:z.object({space_id:uuid,question:z.string().trim().min(2).max(300),expectation:z.enum(["find","no_match"]),expected_record_id:uuid.nullable(),request_id:uuid}).refine(v=>v.expectation==="find"?!!v.expected_record_id:v.expected_record_id===null,"Choose an expected entry, or expect no match."),
  delete_retrieval_case:z.object({space_id:uuid,case_id:uuid}),
  prepare_source:z.object({space_id:uuid,version_id:uuid,approved:z.literal(true),disclosure_version:z.literal(AI_DISCLOSURE_VERSION),request_id:uuid}),
  stop_preparation:z.object({space_id:uuid,version_id:uuid}),
  create_space:z.object({name,kind:z.enum(["person","business","project","collection"]).default("collection"),request_id:uuid}),
  update_space:z.object({space_id:uuid,revision:z.number().int(),name,description:z.string().trim().max(5000),contact_email:z.string().trim().max(200).refine(s=>!s||z.string().email().safeParse(s).success,"Use a valid email address.")}),
  source_intake:sourceInput,
  complete_upload:z.object({space_id:uuid,version_id:uuid}),
  retry_job:z.object({space_id:uuid,job_id:uuid}),
  cancel_job:z.object({space_id:uuid,job_id:uuid}),
  archive_source:z.object({space_id:uuid,source_id:uuid}),
  review_candidate:z.object({space_id:uuid,candidate_id:uuid,revision:z.number().int(),decision:z.enum(["accept","exclude"]),verification_reviewed:z.boolean().default(false),title:name,text:z.string().trim().min(1).max(40000),kind:recordKind,fields,context,links,record_id:uuid.optional(),record_revision:z.number().int().optional(),public_source_url:z.string().max(2000).refine(s=>!s||(z.string().url().safeParse(s).success&&s.startsWith("https://"))).default("")}),
  create_record:z.object({space_id:uuid,request_id:uuid,title:name,text:z.string().trim().min(1).max(40000),kind:recordKind,fields,context,links,public_source_url:z.string().max(2000).refine(s=>!s||(z.string().url().safeParse(s).success&&s.startsWith("https://"))).default("")}),
  edit_record:z.object({space_id:uuid,record_id:uuid,revision:z.number().int(),title:name,text:z.string().trim().min(1).max(40000),kind:recordKind,fields,context,links,active:z.boolean(),public_source_url:z.string().max(2000).refine(s=>!s||(z.string().url().safeParse(s).success&&s.startsWith("https://"))).default("")}),
  publish_release:z.object({space_id:uuid,revision:z.number().int(),reviewed:z.literal(true),summary:z.string().trim().max(500),request_id:uuid}),
  rollback_release:z.object({space_id:uuid,release_id:uuid,reviewed:z.literal(true)}),
  unpublish:z.object({space_id:uuid,reviewed:z.literal(true)}),
} as const;

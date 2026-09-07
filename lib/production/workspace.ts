import type {Activity,KnowledgeRecord,Role} from "./types";
import {entryType,matchesType} from "./knowledge";

export type WorkspaceMember = {user_id:string;email:string;role:Role;created_at:string};
export type WorkspaceInvitation = {id:string;email:string;role:"editor"|"viewer";created_at:string;expires_at:string;accepted_at:string|null;revoked_at:string|null};
export type WorkspaceSettings = {
  members:WorkspaceMember[];
  invitations:WorkspaceInvitation[];
  usage:{sources:number;archived_sources:number;versions:number;stored_bytes:number;records:number;included_records:number;pending_reviews:number;releases:number;events:number};
};
export type RecordDirectory = {items:KnowledgeRecord[];count:number;types:string[]};
export const activityLabels:Record<string,string>={
  "ai.authorized":"Approved a source for preparation","ai.stopped":"Stopped preparation","presence.created":"Created this workspace",
  source_intake:"Added a source version",complete_upload:"Completed an upload",retry_job:"Retried source reading",cancel_job:"Cancelled source reading",
  archive_source:"Archived a source",restore_source:"Restored a source",review_candidate:"Reviewed a suggestion",create_record:"Added a knowledge entry",
  edit_record:"Updated a knowledge entry",update_space:"Updated presence details",publish_release:"Published a release",rollback_release:"Restored an earlier release",
  unpublish:"Unpublished the presence","source.prepared":"Prepared source suggestions",create_invitation:"Created an invitation",revoke_invitation:"Revoked an invitation",
  accept_invitation:"Joined the workspace",update_member:"Updated a member’s access",remove_member:"Removed a member",leave_workspace:"Left the workspace",
};
export function activityLabel(activity:Pick<Activity,"action">){return activityLabels[activity.action]||activity.action.replace(/[_.]/g," ");}
export function invitationState(invitation:WorkspaceInvitation){return invitation.revoked_at?"Revoked":invitation.accepted_at?"Accepted":new Date(invitation.expires_at).getTime()<=Date.now()?"Expired":"Pending";}
export function invitationToken(){return Array.from(crypto.getRandomValues(new Uint8Array(32)),byte=>byte.toString(16).padStart(2,"0")).join("");}
export function filterDirectory(records:KnowledgeRecord[],query="",type="",status="all",offset=0,limit=24):RecordDirectory{
  const needle=query.trim().normalize("NFKC").toLocaleLowerCase();
  const filtered=records.filter(record=>(!type||matchesType(record,type))&&(status==="all"||(status==="included"?record.active:!record.active))&&JSON.stringify([record.title,record.text,record.fields,record.context]).normalize("NFKC").toLocaleLowerCase().includes(needle)).sort((a,b)=>b.updated_at.localeCompare(a.updated_at)||a.id.localeCompare(b.id));
  return {items:filtered.slice(offset,offset+limit),count:filtered.length,types:[...new Set(records.map(entryType))].sort((a,b)=>a.localeCompare(b))};
}

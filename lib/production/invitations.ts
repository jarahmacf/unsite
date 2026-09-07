export function invitationFromUrl(url:URL){
  const id=url.searchParams.get("invite"),token=url.searchParams.get("token");
  return id&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)&&token&&/^[0-9a-f]{64}$/.test(token)?{invitation_id:id,token}:null;
}
export function invitationReturnPath(value:unknown){
  if(typeof value!=="string"||value.length>300||!value.startsWith("/?"))return "/";
  const invitation=invitationFromUrl(new URL(value,"https://unsite.invalid"));
  return invitation?"/?"+new URLSearchParams({invite:invitation.invitation_id,token:invitation.token}):"/";
}

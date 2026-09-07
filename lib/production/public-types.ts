// Dependency-free types shared with the public Deno delivery runtime.
export type Publisher={entity_type:"Organization"|"Person"|"CreativeWork"|"Thing";official_url:string;aliases:string[];profile_urls:string[];revision:number};
export type PublicResource={id:string;title:string;description:string;url:string;mime_type:string;version_label:string;as_of:string|null;revision:number;active?:boolean};

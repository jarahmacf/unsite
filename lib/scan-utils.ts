export function normalizeWebsite(value:string):URL{
  const clean=value.trim();
  if(!clean||clean.length>2000)throw new Error("Enter a valid website address.");
  let url:URL;
  try{url=new URL(/^[a-z][a-z0-9+.-]*:/i.test(clean)?clean:"https://"+clean)}catch{throw new Error("Enter a valid website address, such as yourbusiness.com.")}
  if(url.protocol!=="https:")throw new Error("Use the secure HTTPS version of your website.");
  const host=url.hostname.toLowerCase().replace(/\.$/,"");
  if(url.username||url.password||url.port||!host.includes(".")||host.includes(":")||/^\d+\.\d+\.\d+\.\d+$/.test(host)||/(?:^|\.)(localhost|local|internal|home|lan|test|invalid|example|onion)$/.test(host))throw new Error("Please use a public website domain.");
  url.hostname=host;url.hash="";url.search="";
  return url;
}
export function publicAddress(address:string):boolean{
  if(address.includes(":")){
    const first=parseInt(address.split(":")[0],16);
    return first>=0x2000&&first<=0x3fff&&!/^2001:(?:0*:|0*db8:)/i.test(address)&&!/^2002:/i.test(address);
  }
  const p=address.split(".").map(Number);
  if(p.length!==4||p.some(n=>!Number.isInteger(n)||n<0||n>255))return false;
  const [a,b,c]=p;
  return !(a===0||a===10||a===127||a>=224||(a===100&&b>=64&&b<=127)||(a===169&&b===254)||(a===172&&b>=16&&b<=31)||(a===192&&(b===168||b===0||b===2))||(a===198&&(b===18||b===19||b===51&&c===100))||(a===203&&b===0&&c===113));
}
export function robotsAllows(text:string,url:URL,userAgent="portbot"):boolean{
  const groups:{agents:string[];rules:{allow:boolean;path:string}[]}[]=[];
  let current:{agents:string[];rules:{allow:boolean;path:string}[]}|undefined;
  let sawRule=false;
  for(const raw of text.split(/\r?\n/)){
    const line=raw.split("#")[0].trim();const colon=line.indexOf(":");if(colon<0)continue;
    const key=line.slice(0,colon).trim().toLowerCase();const value=line.slice(colon+1).trim();
    if(key==="user-agent"){
      if(!current||sawRule){current={agents:[],rules:[]};groups.push(current);sawRule=false}
      current.agents.push(value.toLowerCase());
    }else if(current&&(key==="allow"||key==="disallow")){sawRule=true;if(value)current.rules.push({allow:key==="allow",path:value})}
  }
  const specific=groups.filter(g=>g.agents.some(a=>a!=="*"&&userAgent.toLowerCase().includes(a)));
  const selected=specific.length?specific:groups.filter(g=>g.agents.includes("*"));
  let winner={length:-1,allow:true};
  const target=url.pathname+url.search;
  for(const group of selected)for(const rule of group.rules){
    const anchored=rule.path.endsWith("$");const raw=anchored?rule.path.slice(0,-1):rule.path;
    const pattern=raw.split("*").map(s=>s.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join(".*");
    if(new RegExp("^"+pattern+(anchored?"$":"")).test(target)){
      const length=raw.replace(/\*/g,"").length;
      if(length>winner.length||(length===winner.length&&rule.allow))winner={length,allow:rule.allow};
    }
  }
  return winner.allow;
}
export function childLinks(links:string[],root:URL):URL[]{
  const candidates=new Map<string,URL>();
  for(const link of links){
    try{
      const parsed=normalizeWebsite(new URL(link,root).href);
      if(parsed.origin!==root.origin||parsed.href===root.href||/\.(?:pdf|png|jpg|jpeg|gif|webp|svg|zip|css|js|xml|json|mp4)$/i.test(parsed.pathname)||/\/(?:login|logout|signin|signout|account|admin|checkout|cart|delete|remove|wp-admin)(?:\/|$)/i.test(parsed.pathname))continue;
      candidates.set(parsed.href,parsed);
    }catch{/* Ignore unsupported links. */}
  }
  const score=(u:URL)=>/\/(?:about|services|contact|pricing|offerings|team)/i.test(u.pathname)?0:1;
  return [...candidates.values()].sort((a,b)=>score(a)-score(b)).slice(0,12);
}

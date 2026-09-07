export class ProcessingError extends Error {
  constructor(public code:string,message:string,public disposition:"blocked"|"retry"|"failed"="failed"){super(message);}
}
export async function sha256(text:string){return [...new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(text)))].map(n=>n.toString(16).padStart(2,"0")).join("");}
export function chunks(text:string,size=12000):string[]{
  if(!text.trim())throw new ProcessingError("NO_TEXT","No readable text was found. Scanned PDFs need a text layer; upload an accessible PDF or paste its text.");
  if(text.length>200000)throw new ProcessingError("TEXT_LIMIT","This source has more than 200,000 characters. Split it into smaller documents.");
  const out:string[]=[];
  for(let start=0;start<text.length;){let end=Math.min(start+size,text.length);if(end<text.length){const boundary=text.lastIndexOf("\n",end);if(boundary>start+size/2)end=boundary;}out.push(text.slice(start,end));start=end;}
  return out;
}

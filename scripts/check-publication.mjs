// Reproducible, read-only external API/MCP check. No AI provider is contacted.
import {build} from "esbuild";
import {fileURLToPath} from "node:url";
const [base,releaseId]=process.argv.slice(2);
if(!base||!/^https:\/\/[^/]+\/functions\/v1\/unsite\/v2\/[a-f0-9-]{36}$/.test(base)||!releaseId||!/^[a-f0-9-]{36}$/.test(releaseId))throw Error("Usage: node scripts/check-publication.mjs https://PROJECT.supabase.co/functions/v1/unsite/v2/SPACE_UUID RELEASE_UUID");
const path=fileURLToPath(new URL("../lib/production/delivery-check.ts",import.meta.url));
const compiled=await build({entryPoints:[path],bundle:true,format:"esm",platform:"node",write:false});
const {checkDelivery}=await import("data:text/javascript;base64,"+Buffer.from(compiled.outputFiles[0].text).toString("base64"));
const result=await checkDelivery(base,releaseId);console.log(JSON.stringify(result,null,2));if(!result.passed)process.exitCode=1;

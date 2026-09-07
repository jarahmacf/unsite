import { normalizeWebsite, publicAddress, robotsAllows } from "../../../lib/scan-utils.ts";
import { boundedText } from "./crawler.ts";
type Deps = { fetch: typeof fetch; resolve: (host: string) => Promise<string[]> };
type Rest = (path: string, body?: unknown) => Promise<any>;
async function checked(url: URL, deps: Deps) {
  const safe = normalizeWebsite(url.href); safe.search = url.search;
  const ips = await deps.resolve(safe.hostname);
  if (!ips.length || ips.some(ip => !publicAddress(ip))) throw new Error("The URL does not resolve exclusively to public addresses.");
  return safe;
}
async function rules(url: URL, deps: Deps) {
  const response = await deps.fetch(new URL("/robots.txt", url), { redirect: "manual", headers: { "User-Agent": "UnsiteBot/1.0" }, signal: AbortSignal.timeout(8000) });
  if ([404, 410].includes(response.status)) { await response.body?.cancel(); return; }
  if (!response.ok) { await response.body?.cancel(); throw new Error("The website's crawling rules could not be checked."); }
  if (!robotsAllows(await boundedText(response, 256000), url, "unsitebot")) throw new Error("The website's crawling rules disallow this resource check.");
}
export async function checkPublicResource(input: { url: string; mime_type: string }, deps: Deps) {
  let url = new URL(input.url);
  for (let hop = 0; hop < 5; hop++) {
    url = await checked(url, deps); await rules(url, deps);
    const init = { redirect: "manual" as const, headers: { "User-Agent": "UnsiteBot/1.0", Accept: "*/*" }, signal: AbortSignal.timeout(10000) };
    let response = await deps.fetch(url, { ...init, method: "HEAD" });
    if ([405, 501].includes(response.status)) {
      await response.body?.cancel(); await checked(url, deps);
      response = await deps.fetch(url, { ...init, method: "GET", headers: { ...init.headers, Range: "bytes=0-1023" } });
    }
    const code = response.status, location = response.headers.get("location"), mime = (response.headers.get("content-type") || "").split(";")[0].trim().toLowerCase();
    await response.body?.cancel(); // Resource bodies and credentials are never retained.
    if (code >= 300 && code < 400) { if (!location) throw new Error("The resource redirects without a destination."); url = new URL(location, url); continue; }
    if (code < 200 || code >= 300) return { ok: false, http_status: code, error: "The resource returned HTTP " + code + ".", final_url: url.href };
    return { ok: true, http_status: code, final_url: url.href, content_type: mime || null, warning: !mime ? "The resource did not declare a content type." : mime !== input.mime_type.toLowerCase() ? "The returned content type differs from the approved catalog." : null };
  }
  throw new Error("The resource redirected too many times.");
}
async function readHostFile(hostname: string, path: string, max: number, deps: Deps) {
  const url = await checked(new URL("https://" + hostname + path), deps);
  const response = await deps.fetch(url, { redirect: "manual", headers: { "User-Agent": "UnsiteBot/1.0", Accept: "application/json, text/plain" }, signal: AbortSignal.timeout(12000) });
  if (!response.ok) { await response.body?.cancel(); throw new Error("The hostname did not serve the expected verification file over HTTPS."); }
  return boundedText(response, max);
}
export async function checkHosting(input: { hostname: string; probe_token: string }, spaceId: string, deps: Deps) {
  const body = JSON.parse(await readHostFile(input.hostname, "/.well-known/unsite-host", 2000, deps));
  return { ok: body.space_id === spaceId && body.hostname === input.hostname && body.probe_token === input.probe_token, method: "https_workspace_proof" };
}
export async function submitIndexNow(input: { hostname: string; key: string; urls: string[] }, deps: Deps) {
  const host = normalizeWebsite("https://" + input.hostname);
  if (host.hostname !== input.hostname || !/^[a-f0-9]{64}$/.test(input.key) || !Array.isArray(input.urls) || !input.urls.length || input.urls.length > 10000) throw new Error("Invalid search submission scope.");
  for (const value of input.urls) {
    const u = new URL(value);
    if (u.origin !== host.origin || u.search || u.hash || (u.pathname !== "/" && !/^\/records\/[0-9a-f-]{36}$/.test(u.pathname))) throw new Error("Search submissions are limited to this hostname's public knowledge URLs.");
  }
  const keyLocation = host.origin + "/" + input.key + ".txt";
  if ((await readHostFile(input.hostname, "/" + input.key + ".txt", 256, deps)).trim() !== input.key) throw new Error("The search verification file did not match. Check the hostname connection.");
  const response = await deps.fetch("https://api.indexnow.org/indexnow", {
    method: "POST", redirect: "error", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ host: input.hostname, key: input.key, keyLocation, urlList: [...new Set(input.urls)] }), signal: AbortSignal.timeout(15000),
  });
  const status = response.status, retry = response.headers.get("Retry-After"); await response.body?.cancel();
  return { ok: [200, 202].includes(status), http_status: status, url_count: new Set(input.urls).size,
    state: status === 200 ? "received" : status === 202 ? "validation_pending" : "rejected", indexed: null,
    ...([200, 202].includes(status) ? {} : { error: "IndexNow returned HTTP " + status + ".", retryable: status === 429 || status >= 500, retry_after: /^\d+$/.test(retry || "") ? Math.min(86400, Number(retry)) : 3600 }) };
}
export async function runLaunchStep(rest: Rest, deps: Deps) {
  const task = await rest("rpc/unsite_claim_launch_job", {}); if (!task) return false;
  let result: unknown;
  try {
    result = task.kind === "host" ? await checkHosting(task.payload, task.space_id, deps)
      : task.kind === "resource" ? await checkPublicResource(task.payload, deps) : await submitIndexNow(task.payload, deps);
  } catch (error) { result = { ok: false, error: error instanceof Error && error.name === "Error" ? error.message.slice(0,500) : "The check could not finish. Check the hostname or resource and retry.", retryable: task.kind === "indexnow", retry_after: 3600 }; }
  await rest("rpc/unsite_launch_result", { p_id: task.id, p_lease: task.lease, p_result: result });
  return true;
}

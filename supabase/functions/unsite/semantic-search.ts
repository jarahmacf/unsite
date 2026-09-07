import { embedTexts, queryConsent } from "../../../lib/production/embeddings.ts";
import { indexedQuery, searchKnowledge } from "../../../lib/production/retrieval.ts";
import type { PublicRelease, PublishedRecord } from "../../../lib/production/release.ts";
export class SearchFailure extends Error { constructor(public status: number, message: string) { super(message); } }
export async function semanticSearch(options: {
  query: string; consent?: string; limit: number; type?: string; kind?: string; topic?: string;
  release: PublicRelease & { semantic_ready?: boolean }; base: string; key: string;
  rpc: (name: string, body: unknown) => Promise<unknown>; requestFetch: typeof fetch;
}) {
  const { query, consent, limit, release, base, key, rpc } = options;
  if (consent !== queryConsent) throw new SearchFailure(400, "Semantic search sends this query to OpenAI for an embedding. Supply provider_consent=openai-query-embedding-v1 to authorize that request.");
  if (!key || !release.semantic_ready) throw new SearchFailure(409, "Semantic search is unavailable for this release. Lexical search remains available.");
  if (!await rpc("unsite_semantic_query_budget", { sid: release.space_id, rid: release.id })) throw new SearchFailure(429, "The semantic query limit was reached or availability changed. Use lexical search or retry after the daily limit resets.");
  const vector = await embedTexts([query], key, options.requestFetch);
  const found = await rpc("unsite_hybrid_records", { sid: release.space_id, rid: release.id, query_text: indexedQuery(query), query_vector: vector.embeddings[0], match_count: limit, type_filter: options.type || "", kind_filter: options.kind || "", topic_filter: options.topic || "" }) as { records: PublishedRecord[]; total: number; changed?: boolean; unavailable?: boolean } | null;
  if (!found) throw new SearchFailure(404, "Publication not found.");
  if (found.changed || found.unavailable) throw new SearchFailure(409, "Publication or semantic availability changed. Rediscover before continuing.");
  // Preserve database hybrid order. The shared formatter supplies qualified
  // excerpts; it must not rerank semantic-only matches with lexical scores.
  const formatted = searchKnowledge({ ...release.data, records: found.records }, query, { limit: 20, indexedMatches: true, base, release_id: release.id });
  const hits = new Map(formatted.results.map(r => [r.id, r]));
  const results = found.records.map(r => hits.get(r.id)).filter(Boolean).slice(0, limit);
  return { query, results, total: found.total, matched: results.length > 0, retrieval: { method: "hybrid lexical and semantic search", fusion: "reciprocal rank fusion", provider: "OpenAI", model: "text-embedding-3-small", dimensions: 512, answer_generation: false } };
}

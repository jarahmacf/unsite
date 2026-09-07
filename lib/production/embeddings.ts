// Fixed, versioned contract shared by the public API and background indexer.
export const embeddingModel = "text-embedding-3-small";
export const embeddingDimensions = 512;
export const embeddingConsent = "openai-public-embeddings-v1";
export const queryConsent = "openai-query-embedding-v1";
export class EmbeddingError extends Error {
  constructor(public code: "provider_missing" | "provider_uncertain" | "invalid_input", message: string) { super(message); }
}
export function validEmbedding(value: unknown): value is number[] {
  return Array.isArray(value) && value.length === embeddingDimensions && value.every(n => typeof n === "number" && Number.isFinite(n)) && value.some(n => n !== 0);
}
export async function embedTexts(inputs: string[], key: string, requestFetch: typeof fetch = fetch) {
  if (!key) throw new EmbeddingError("provider_missing", "An operator needs to configure the embedding provider.");
  if (!inputs.length || inputs.length > 16 || inputs.some(s => !s.trim() || Array.from(s).length > 2000)) throw new EmbeddingError("invalid_input", "Embedding inputs exceed the approved batch limit.");
  // No automatic retries: an interrupted provider request may already be billed.
  try {
    const response = await requestFetch("https://api.openai.com/v1/embeddings", {
      method: "POST", headers: { Authorization: "Bearer " + key, "Content-Type": "application/json" },
      body: JSON.stringify({ model: embeddingModel, dimensions: embeddingDimensions, encoding_format: "float", input: inputs }),
      signal: AbortSignal.timeout(25000), redirect: "error",
    });
    if (!response.ok) { await response.body?.cancel(); throw new Error("Provider request failed"); }
    const reader = response.body?.getReader(); let size = 0; const parts: Uint8Array[] = [];
    if (!reader) throw new Error("Missing provider response");
    try { for (;;) { const p = await reader.read(); if (p.done) break; size += p.value.length; if (size > 2000000) throw new Error("Provider response too large"); parts.push(p.value); } } finally { await reader.cancel(); }
    const bytes = new Uint8Array(size); let offset = 0; for (const p of parts) { bytes.set(p, offset); offset += p.length; }
    const result = JSON.parse(new TextDecoder().decode(bytes)) as { data?: { index: number; embedding: number[] }[]; usage?: { total_tokens?: number } };
    if (!Array.isArray(result.data) || result.data.length !== inputs.length) throw new Error("Invalid provider response");
    const data = [...result.data].sort((a, b) => a.index - b.index);
    if (data.some((d, i) => d.index !== i || !validEmbedding(d.embedding))) throw new Error("Invalid embedding dimensions");
    return { embeddings: data.map(d => d.embedding), tokens: Number.isSafeInteger(result.usage?.total_tokens) ? result.usage!.total_tokens! : null };
  } catch { throw new EmbeddingError("provider_uncertain", "The embedding request did not finish with a saved result. Retrying may incur another provider charge."); }
}

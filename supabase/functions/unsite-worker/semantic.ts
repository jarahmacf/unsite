import { embedTexts, EmbeddingError } from "../../../lib/production/embeddings.ts";
type Rest = (path: string, body?: unknown) => Promise<any>;
export async function runEmbeddingStep(rest: Rest, key: string, requestFetch: typeof fetch = fetch) {
  const task = await rest("rpc/unsite_claim_embeddings", {});
  if (!task) return false;
  const finish = (result: unknown) => rest("rpc/unsite_embedding_result", { p_release: task.release_id, p_lease: task.lease, p_result: result });
  try {
    const result = await embedTexts(task.chunks.map((c: { content: string }) => c.content), key, requestFetch);
    await finish({ chunks: task.chunks.map((c: { id: string }, i: number) => ({ id: c.id, embedding: result.embeddings[i] })), tokens: result.tokens });
  } catch (error) {
    await finish({ error: error instanceof EmbeddingError ? error.message : "The index could not save a checkpoint. Review before retrying; another provider charge is possible.", code: error instanceof EmbeddingError ? error.code : "provider_uncertain" });
  }
  return true;
}

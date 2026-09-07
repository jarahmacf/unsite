export const CONTENT_TYPES = ["about", "offering", "faq", "policy", "article", "general"] as const;
export type ContentType = typeof CONTENT_TYPES[number];
export type ContextEntry = {
  id: string; title: string; type: ContentType; content: string; included: boolean;
  source: { kind: "text" | "file" | "url"; label: string; url: string; original: string };
};
export type UnsiteDraft = {
  profile: { name: string; kind: "person" | "business"; description: string; email: string };
  entries: ContextEntry[];
};
export type Publication = { baseUrl: string; revision: number; publishedAt: string; sourceRevision: number };
export type Workspace = { id: string; draft: UnsiteDraft; revision: number; updatedAt: string; publication: Publication | null };
export type WorkspaceSummary = Omit<Workspace, "draft"> & { name: string };
export type PublicContent = { schema_version: "1.0"; profile: UnsiteDraft["profile"]; content: { id: string; title: string; type: ContentType; text: string; source_url?: string }[] };

export function emptyDraft(): UnsiteDraft {
  return { profile: { name: "", kind: "person", description: "", email: "" }, entries: [] };
}
export function publicContent(draft: UnsiteDraft): PublicContent {
  return {
    schema_version: "1.0",
    profile: { name: draft.profile.name, kind: draft.profile.kind, description: draft.profile.description, email: draft.profile.email },
    content: draft.entries.filter(e => e.included).map(e => ({
      id: e.id, title: e.title, type: e.type, text: e.content,
      ...(e.source.url ? { source_url: e.source.url } : {}),
    })),
  };
}
export function contentMarkdown(data: PublicContent): string {
  return [`# ${data.profile.name}`, data.profile.description,
    ...(data.profile.email ? [`Contact: ${data.profile.email}`] : []),
    ...data.content.map(e => `## ${e.title}\n\n${e.text}${e.source_url ? `\n\nSource: ${e.source_url}` : ""}`),
  ].join("\n\n") + "\n";
}

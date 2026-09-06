import type { Job, Source, SourceVersion } from "@/lib/production/types";

export function latestVersion(versions: SourceVersion[], sourceId: string) {
  return versions.filter(version => version.source_id === sourceId).reduce<SourceVersion | undefined>((latest, version) => !latest || version.version > latest.version ? version : latest, undefined);
}

export function sourceStatus(source: Source, version?: SourceVersion, job?: Job): { label: string; tone: "neutral" | "green" | "amber" | "red"; note: string } {
  if (source.archived_at) return { label: "Archived", tone: "neutral", note: "Originals preserved" };
  if (!version) return { label: "Awaiting upload", tone: "neutral", note: "No saved version yet" };
  if (job?.status === "completed") return { label: "Prepared", tone: "green", note: "Ready for review" };
  if (job?.status === "failed") return { label: "Needs attention", tone: "red", note: "Open source to retry" };
  if (job?.status === "blocked") {
    if (job.error_code === "AI_APPROVAL_REQUIRED") return { label: "Saved", tone: "neutral", note: "AI preparation optional" };
    if (job.error_code === "PROVIDER_UNCERTAIN") return { label: "Review needed", tone: "amber", note: "Check preparation status" };
    return { label: "Preparation paused", tone: "amber", note: "Original saved privately" };
  }
  if (job?.status === "running") return { label: "Processing", tone: "neutral", note: `${Math.round(job.progress)}% complete` };
  if (job?.status === "queued") return { label: "Queued", tone: "neutral", note: "Waiting to be read" };
  if (job?.status === "cancelled") return { label: "Stopped", tone: "neutral", note: "Original preserved" };
  return version.text_content || version.extracted_text
    ? { label: "Saved", tone: "neutral", note: "Private original" }
    : { label: "Awaiting upload", tone: "neutral", note: "Upload not completed" };
}

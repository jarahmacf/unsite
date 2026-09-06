import { api } from "./shared";

// Sources use an explicit transport so the development sample can never fall
// through to live storage, preparation, authentication, or publication.
export type SourceGateway = {
  request: typeof api;
  upload: (signedUrl: string, file: File, contentType: string) => Promise<void>;
  sample?: boolean;
};

export const liveSourceGateway: SourceGateway = {
  request: api,
  async upload(signedUrl, file, contentType) {
    const uploaded = await fetch(signedUrl, { method: "PUT", headers: { "Content-Type": contentType, "x-upsert": "false" }, body: file });
    // A retry may encounter an immutable object that was uploaded successfully.
    // complete_upload independently verifies its size before marking it complete.
    if (!uploaded.ok) {
      let reason;
      try { reason = await uploaded.json(); } catch { /* Preserve the actionable upload error. */ }
      if (uploaded.status !== 409 && reason?.error !== "Duplicate" && reason?.statusCode !== "409") {
        throw new Error(file.name + ": upload interrupted. Retry to continue; completed files are saved.");
      }
    }
  },
};

import { DemoWorkspace } from "./demo-workspace";

export const metadata = { title: "Unsite — Explore the workspace", description: "Explore Unsite with sample content. No sign-in required.", robots: { index: false, follow: false } };

export default function DemoPage() {
  return <DemoWorkspace />;
}

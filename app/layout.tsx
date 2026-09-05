import type { Metadata } from "next";
import "./globals.css";
import "./workspace.css";
export const metadata:Metadata={title:"Unsite — Your content, ready for agents",description:"Collect your context, review what you share, and publish a machine-readable presence on the web.",icons:{icon:"/favicon.svg"}};
export default function RootLayout({children}:Readonly<{children:React.ReactNode}>){return <html lang="en"><body>{children}</body></html>}

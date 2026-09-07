import type { Metadata } from "next";
import "./globals.css";
import "./workspace.css";
export const metadata:Metadata={referrer:"no-referrer",title:"Unsite — Your content, ready for agents",description:"Collect your context, review what you share, and publish a machine-readable presence on the web.",icons:{icon:"/favicon.svg"}};
export default function RootLayout({children}:Readonly<{children:React.ReactNode}>){return <html lang="en"><head><link rel="preload" href="/fonts/geist-latin.woff2" as="font" type="font/woff2" crossOrigin="anonymous"/><link rel="preload" href="/fonts/outfit-latin.woff2" as="font" type="font/woff2" crossOrigin="anonymous"/></head><body>{children}</body></html>}

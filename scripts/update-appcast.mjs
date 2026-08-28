// Maintain the Sparkle appcast feed at the repository root. Sparkle reads this
// file via raw.githubusercontent.com; every release prepends one <item>.
import { readFile, writeFile } from "node:fs/promises"
import { existsSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { removeExistingItem } from "./appcastDedup.mjs"

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const appcastPath = path.join(root, "appcast.xml")

const args = process.argv.slice(2)
function flag(name) {
  const index = args.indexOf(name)
  if (index === -1 || index + 1 >= args.length) throw new Error(`Missing ${name}`)
  return args[index + 1]
}

const version = flag("--version")
const build = flag("--build")
const url = flag("--url")
const signature = flag("--signature")
const length = flag("--length")
const notes = flag("--notes")

function escape(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
}

const item = [
  "    <item>",
  `      <title>${escape(version)}</title>`,
  `      <sparkle:version>${escape(build)}</sparkle:version>`,
  `      <sparkle:shortVersionString>${escape(version)}</sparkle:shortVersionString>`,
  "      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>",
  `      <sparkle:releaseNotesLink>${escape(notes)}</sparkle:releaseNotesLink>`,
  `      <pubDate>${new Date().toUTCString()}</pubDate>`,
  `      <enclosure url="${escape(url)}" type="application/octet-stream" sparkle:edSignature="${escape(signature)}" length="${escape(length)}"/>`,
  "    </item>"
].join("\n")

const header = [
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
  "<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">",
  "  <channel>",
  "    <title>Kimi Code Agent Releases</title>",
  "    <link>https://github.com/shidesheng0218/kimi-code-agent/releases</link>",
  "    <description>macOS releases for Kimi Code Agent (arm64).</description>",
  "    <language>zh-CN</language>"
].join("\n")

let content
if (existsSync(appcastPath)) {
  const existing = await readFile(appcastPath, "utf8")
  const withoutDuplicate = removeExistingItem(existing, build)
  const marker = "<language>zh-CN</language>"
  const anchorIndex = withoutDuplicate.indexOf(marker)
  if (anchorIndex === -1) throw new Error("appcast.xml is missing its <language> anchor; refusing to rewrite")
  const insertAt = anchorIndex + marker.length
  content = `${withoutDuplicate.slice(0, insertAt)}\n${item}\n${withoutDuplicate.slice(insertAt)}`
} else {
  content = `${header}\n${item}\n  </channel>\n</rss>\n`
}

await writeFile(appcastPath, content, "utf8")
console.log(`appcast.xml updated with ${version} (build ${build})`)

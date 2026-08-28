// Pure helper extracted from update-appcast.mjs so its dedup behavior can be
// unit tested directly (vitest) instead of only via appcast.xml regression
// snapshots. Repeated local/CI packaging runs for the same version must
// replace the prior <item> for that <sparkle:version>, not append another
// copy — an unconditional prepend once accumulated 14 duplicate 0.4.0
// entries in appcast.xml before this fix.
//
// Type signature lives in appcastDedup.d.ts (this file is plain .mjs since
// it's also run directly by Node from update-appcast.mjs).
export function removeExistingItem(xml, targetVersion) {
  const itemPattern = /[ \t]*<item>[\s\S]*?<\/item>\n?/g
  let match
  while ((match = itemPattern.exec(xml)) !== null) {
    const versionMatch = /<sparkle:version>([^<]*)<\/sparkle:version>/.exec(match[0])
    if (versionMatch && versionMatch[1] === targetVersion) {
      return xml.slice(0, match.index) + xml.slice(match.index + match[0].length)
    }
  }
  return xml
}

import { describe, expect, it, beforeAll } from 'vitest';

// scripts/appcastDedup.mjs is a plain ESM script (also run directly by Node
// from update-appcast.mjs), not a TypeScript module with a declaration file,
// and this repo's package.json sets "type": "commonjs" so it can't be
// statically imported from a .ts file either. Load it dynamically and type
// the binding by hand instead of fighting module-resolution edge cases.
let removeExistingItem: (xml: string, targetVersion: string) => string;
beforeAll(async () => {
  // @ts-expect-error -- plain .mjs script with no declaration file; see comment above.
  const mod = await import('../../scripts/appcastDedup.mjs');
  removeExistingItem = (mod as { removeExistingItem: (xml: string, targetVersion: string) => string })
    .removeExistingItem;
});

/**
 * Regression coverage for the appcast dedup bug: every packaging run used to
 * unconditionally prepend a new <item>, which silently accumulated 14
 * duplicate 0.4.0 entries in appcast.xml before this fix. removeExistingItem
 * must strip any prior <item> for the same sparkle:version before a new one
 * is inserted, so repeated builds of the same version replace rather than
 * pile up.
 */
describe('removeExistingItem', () => {
  const sampleItem = (version: string, pubDate: string) =>
    [
      '    <item>',
      `      <title>${version}</title>`,
      `      <sparkle:version>${version}</sparkle:version>`,
      `      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>`,
      '      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>',
      `      <sparkle:releaseNotesLink>https://example.com/${version}</sparkle:releaseNotesLink>`,
      `      <pubDate>${pubDate}</pubDate>`,
      `      <enclosure url="https://example.com/${version}.zip" type="application/octet-stream" sparkle:edSignature="sig" length="100"/>`,
      '    </item>',
    ].join('\n');

  const wrap = (itemsXml: string) =>
    [
      '<?xml version="1.0" encoding="utf-8"?>',
      '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
      '  <channel>',
      '    <title>Kimi Code Agent Releases</title>',
      '    <language>zh-CN</language>',
      itemsXml,
      '  </channel>',
      '</rss>',
      '',
    ].join('\n');

  it('removes the single existing item matching the target version', () => {
    const xml = wrap(sampleItem('0.4.0', 'Mon, 01 Jan 2026 00:00:00 GMT'));
    const result = removeExistingItem(xml, '0.4.0');
    expect(result).not.toContain('<sparkle:version>0.4.0</sparkle:version>');
  });

  it('leaves items for other versions untouched', () => {
    const xml = wrap(
      [sampleItem('0.4.0', 'Mon, 01 Jan 2026 00:00:00 GMT'), sampleItem('0.3.4', 'Sun, 01 Dec 2025 00:00:00 GMT')].join(
        '\n',
      ),
    );
    const result = removeExistingItem(xml, '0.4.0');
    expect(result).not.toContain('<sparkle:version>0.4.0</sparkle:version>');
    expect(result).toContain('<sparkle:version>0.3.4</sparkle:version>');
  });

  it('is a no-op when the target version is not present', () => {
    const xml = wrap(sampleItem('0.3.4', 'Sun, 01 Dec 2025 00:00:00 GMT'));
    const result = removeExistingItem(xml, '0.4.0');
    expect(result).toBe(xml);
  });

  it('collapses N duplicate entries for the same version down to zero when called repeatedly', () => {
    // Reproduces the historical bug shape: many prepended 0.4.0 items.
    const duplicates = Array.from({ length: 14 }, (_, i) =>
      sampleItem('0.4.0', `Mon, ${String(i + 1).padStart(2, '0')} Jan 2026 00:00:00 GMT`),
    ).join('\n');
    let xml = wrap(duplicates);
    expect((xml.match(/<sparkle:version>0\.4\.0<\/sparkle:version>/g) ?? []).length).toBe(14);

    let iterations = 0;
    while ((xml.match(/<sparkle:version>0\.4\.0<\/sparkle:version>/g) ?? []).length > 0) {
      xml = removeExistingItem(xml, '0.4.0');
      iterations += 1;
      if (iterations > 20) throw new Error('removeExistingItem did not converge — infinite loop guard tripped');
    }
    expect(iterations).toBe(14);
    expect(xml).not.toContain('<item>');
  });

  it('produces well-formed XML when a replacement item is reinserted after removal', () => {
    const xml = wrap(sampleItem('0.4.0', 'Mon, 01 Jan 2026 00:00:00 GMT'));
    const withoutOld = removeExistingItem(xml, '0.4.0');
    const marker = '<language>zh-CN</language>';
    const insertAt = withoutOld.indexOf(marker) + marker.length;
    const rebuilt = `${withoutOld.slice(0, insertAt)}\n${sampleItem('0.4.0', 'Tue, 02 Jan 2026 00:00:00 GMT')}\n${withoutOld.slice(insertAt)}`;
    expect((rebuilt.match(/<sparkle:version>0\.4\.0<\/sparkle:version>/g) ?? []).length).toBe(1);
    expect(rebuilt).toContain('Tue, 02 Jan 2026 00:00:00 GMT');
  });
});

# Vendored engine version manifest

This directory is a **packaged snapshot** of the upstream [`sst/opencode`](https://github.com/sst/opencode)
repository, not a git submodule. There is no `.git` directory here and no
automatic way to diff against upstream — this file is the only record of
what's actually in this tree and how it got here.

## Current pinned version

| | |
|---|---|
| Upstream repo | https://github.com/sst/opencode |
| Version | `v1.18.18` |
| Upstream commit | [`31406ccc51b4bd2a4e1e086b2bcaa5f7f804f26d`](https://github.com/sst/opencode/commit/31406ccc51b4bd2a4e1e086b2bcaa5f7f804f26d) |
| Upstream release date | 2026-08-13 |
| License | MIT (see `LICENSE` in this directory; also recorded in the repo root `THIRD_PARTY_NOTICES.md`) |
| Local package version | `vendor/engine/packages/opencode/package.json` → `"version": "1.18.18"` (must match the table above — see "Keeping this file honest" below) |

This is the same version referenced in `THIRD_PARTY_NOTICES.md` at the repo
root ("OpenCode v1.18.18 ... The vendored source ... is retained under
`vendor/engine/`"). If you ever see those two disagree, trust neither until
you've re-derived the truth from `package.json` and this file, and fixed
whichever one is stale.

## How this tree diverges from a plain `git clone` of that commit

1. **Rebranding (behavior-preserving, no engine logic changed).** Commit
   `ca2c920` ("refactor: scrub engine branding to Kimi and fix
   packaged-runtime lifecycle") renamed `vendor/opencode` → `vendor/engine`
   and `src/opencode` → `src/engine` in this repo, and changed how the
   embedded binary is named/labeled at runtime (ships as `runtime/kimi-agent`
   so the process name reads "Kimi", not "opencode"). None of that touched
   files inside this directory — it only affects how the Kimi-side Swift/TS
   code refers to and launches the engine. Original upstream attribution is
   preserved in `LICENSE` (this directory) and `THIRD_PARTY_NOTICES.md` (repo
   root), as required by the MIT license.

2. **Third-party dependency patches (upstream's own, not Kimi's).** The
   `patches/` directory contains 17 pnpm patch files applied to *opencode's
   own dependencies* (e.g. `@modelcontextprotocol/sdk`, `@ai-sdk/*`,
   `effect`, `solid-js`) — these are pnpm's patch mechanism for pinning
   dependency fixes, generated and maintained upstream, not something
   authored in this repo. `grep -rl kimi patches/*.patch` returns nothing;
   verify that's still true after any patch changes, since a Kimi-authored
   patch slipping in here would need separate attribution.

3. **No other modifications.** Everything else under `vendor/engine/` —
   `packages/opencode/src/`, `packages/core/`, `packages/sdk/`, etc. — is
   upstream source as of the pinned commit, unpatched by us. The Kimi
   integration boundary is `KimiHeadlessRuntimeFactory` (writes
   `OPENCODE_CONFIG_CONTENT` to configure the engine at launch) and the
   HTTP/MCP endpoints the engine already exposes — never a source edit
   inside this tree.

## Why a snapshot instead of a submodule

The packaged app ships a compiled engine binary
(`runtime/kimi-agent`), not this source tree — `vendor/engine/` exists so
the binary can be built and so `EngineAPIClient`'s `openapi.json` can be
regenerated from a real running instance (the generation command is recorded
in the commit message of `6e24d11`, which introduced `EngineAPIClient`; see
"Upgrading" below for the command itself). A submodule would pull in
upstream's full git history and `.git` metadata for no benefit here, and
packaging scripts (`scripts/package-kimi-code-agent-native.mjs`) assume a
plain directory they can build in place.

## Upgrading to a newer upstream version

There's no scripted upgrade path yet — this is a manual process:

1. Diff-check what changed upstream between the pinned commit and the target
   version (`git diff <pinned-sha>..<target-sha>` against a *local clone* of
   `sst/opencode`, not this vendored copy) — specifically:
   - the OpenAPI surface (`bun dev generate` output, currently produced with
     `cd vendor/engine/packages/opencode && npx --yes bun@1.3.14 run dev generate`
     — see commit `6e24d11`'s message for the full context) may have
     added/removed/renamed endpoints or schemas, which flows through to
     `EngineAPIClient`'s generated `Types.swift`/`Client.swift`
   - the `provider`/`mcp` config schema (`packages/core/src/v1/config/`) —
     `KimiHeadlessRuntimeFactory`'s config generator hardcodes field names
     against the pinned version's schema (`command`/`environment`/`type` for
     MCP, `npm`/`options`/`models` for providers); a schema change there is a
     silent breakage, not a compile error, since the config blob is loosely
     typed JSON on the Swift side
2. Replace the contents of this directory with the target version's source
   (re-run whatever process originally produced this snapshot — check
   `scripts/` for an extraction/vendoring script if one exists, otherwise a
   fresh `git clone` + strip `.git` + copy).
3. Re-apply or re-derive the pnpm patches in `patches/` — they're pinned to
   specific dependency versions (e.g. `@modelcontextprotocol/sdk@1.29.0`);
   if the target version bumped a patched dependency, the patch file name
   and possibly its contents need updating to match pnpm's patch resolution.
4. Update the table at the top of this file (version, commit SHA, release
   date) and `packages/opencode/package.json`'s `"version"` field, and the
   `THIRD_PARTY_NOTICES.md` line at the repo root — all three must agree.
5. Regenerate `macos/Sources/EngineAPIClient/openapi.json` (see the command
   above). sst/opencode's generated OpenAPI document has historically
   shipped duplicate `tags` entries (e.g. "opencode HttpApi" appeared 4
   times) that `swift-openapi-generator` rejects outright — commit `6e24d11`
   worked around this with an ad-hoc dedup pass (not a checked-in script; it
   was a one-off `node -e`/`jq` transform run by hand — see that commit's
   message for the exact shape) rather than an automated step, so this still
   needs to be redone manually per upgrade until someone writes a real
   `scripts/` entry for it. Then rebuild
   `KimiCodeAgent`/`KimiNativeBridge`/`KimiAgentCoreChecks` to catch config
   schema drift before shipping.
6. Run `npm run verify` end to end, then do a real packaged-app smoke test
   (`npm run native:package`, install, launch, exercise a session) — schema
   drift in the provider/MCP config tends to fail silently (engine logs an
   error and keeps running with that feature disabled) rather than crashing,
   so passing tests alone don't prove the upgrade is safe.

## Keeping this file honest

If you change anything under `vendor/engine/` (bump the version, add a
patch, touch branding), update this file in the same commit. A stale
version manifest is worse than none — someone will trust it.

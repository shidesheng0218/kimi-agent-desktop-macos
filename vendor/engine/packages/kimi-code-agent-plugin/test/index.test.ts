import { describe, expect, test } from 'bun:test'
import { prepareBrowserPlan } from '../src/index'

async function webRequestPreparers() {
  return await import('../src/index') as typeof import('../src/index') & {
    prepareWebSearchRequest?: (input: unknown) => { query: string; maxResults: number }
    prepareWebFetchRequest?: (input: unknown) => { url: string; sourceID?: string; maxCharacters: number }
  }
}

describe('Kimi OpenCode native plugin browser policy', () => {
  test('automatically admits a public read-only browser plan and pins its allowed domain', () => {
    expect(
      prepareBrowserPlan(JSON.stringify({
        steps: [{ kind: 'open', url: 'https://docs.example.com/guide' }, { kind: 'inspect', selector: 'h1' }],
      })),
    ).toEqual({
      plan: {
        allowedDomains: ['docs.example.com'],
        steps: [{ kind: 'open', url: 'https://docs.example.com/guide' }, { kind: 'inspect', selector: 'h1' }],
      },
      requiresApproval: false,
    })
  })

  test('requires explicit approval before a browser plan can click, type or press a key', () => {
    expect(
      prepareBrowserPlan(JSON.stringify({
        allowedDomains: ['example.com'],
        steps: [{ kind: 'open', url: 'https://example.com' }, { kind: 'click', selector: '#submit' }],
      })).requiresApproval,
    ).toBe(true)
  })

  test('rejects private browser targets instead of silently loading them', () => {
    expect(() => prepareBrowserPlan(JSON.stringify({ steps: [{ kind: 'open', url: 'https://127.0.0.1/admin' }] }))).toThrow(
      'private',
    )
  })
})

describe('Kimi OpenCode native plugin web policy', () => {
  test('replaces OpenCode default web tools with the Kimi native bridge names', async () => {
    const module = await import('../src/index')
    const hooks = await module.default.server({} as never, {})

    expect(Object.keys(hooks.tool ?? {}).sort()).toEqual(expect.arrayContaining(['websearch', 'webfetch']))
    expect(hooks.tool?.kimi_web_search).toBeUndefined()
    expect(hooks.tool?.kimi_web_fetch).toBeUndefined()
  })

  test('normalizes a public web search request without asking for approval', async () => {
    const plugin = await webRequestPreparers()

    expect(plugin.prepareWebSearchRequest).toBeTypeOf('function')
    expect(plugin.prepareWebSearchRequest?.({ query: '  Kimi Code Agent  ', maxResults: 99 })).toEqual({
      query: 'Kimi Code Agent',
      maxResults: 8,
    })
  })

  test('normalizes a public fetch request and refuses a credential-bearing URL before it reaches the bridge', async () => {
    const plugin = await webRequestPreparers()

    expect(plugin.prepareWebFetchRequest).toBeTypeOf('function')
    expect(plugin.prepareWebFetchRequest?.({
      url: 'https://docs.example.com/guide',
      sourceID: 'source-1',
      maxCharacters: 999999,
    })).toEqual({
      url: 'https://docs.example.com/guide',
      sourceID: 'source-1',
      maxCharacters: 100000,
    })
    expect(() => plugin.prepareWebFetchRequest?.({ url: 'https://user:password@example.com/' })).toThrow('credential')
  })
})

describe('Kimi OpenCode native plugin declarative hook configuration', () => {
  test('appends configured system prompt rules and leaves output untouched when unset', async () => {
    const { applySystemPromptRules } = await import('../src/index')
    const output = { system: ['base prompt'] }
    applySystemPromptRules(['总是用简体中文回复'], output)
    expect(output.system).toEqual(['base prompt', '总是用简体中文回复'])

    const untouched = { system: ['base prompt'] }
    applySystemPromptRules(undefined, untouched)
    expect(untouched.system).toEqual(['base prompt'])
  })

  test('overrides permission status for a matching tool type and ignores unmatched types', async () => {
    const { applyPermissionOverride } = await import('../src/index')
    const denied = { status: 'ask' as const }
    applyPermissionOverride({ bash: 'deny' }, { type: 'bash' }, denied)
    expect(denied.status).toBe('deny')

    const unaffected = { status: 'ask' as const }
    applyPermissionOverride({ bash: 'deny' }, { type: 'edit' }, unaffected)
    expect(unaffected.status).toBe('ask')
  })

  test('blocks a webfetch call outside the allowed domain list and admits a subdomain match', async () => {
    const { enforceWebFetchAllowlist } = await import('../src/index')
    expect(() =>
      enforceWebFetchAllowlist(['example.com'], { tool: 'webfetch' }, { args: { url: 'https://evil.com' } }),
    ).toThrow('not in the allowed domain list')

    expect(() =>
      enforceWebFetchAllowlist(['example.com'], { tool: 'webfetch' }, { args: { url: 'https://docs.example.com' } }),
    ).not.toThrow()

    // Non-webfetch tools and an unset allowlist are both no-ops.
    expect(() =>
      enforceWebFetchAllowlist(['example.com'], { tool: 'bash' }, { args: { url: 'https://evil.com' } }),
    ).not.toThrow()
    expect(() =>
      enforceWebFetchAllowlist(undefined, { tool: 'webfetch' }, { args: { url: 'https://evil.com' } }),
    ).not.toThrow()
  })

  test('truncates tool output past the configured character limit and appends a notice', async () => {
    const { truncateToolOutput } = await import('../src/index')
    const output = { output: 'x'.repeat(150) }
    truncateToolOutput({ bash: 100 }, { tool: 'bash' }, output)
    expect(output.output.startsWith('x'.repeat(100))).toBe(true)
    expect(output.output).toContain('truncated')

    const short = { output: 'short' }
    truncateToolOutput({ bash: 100 }, { tool: 'bash' }, short)
    expect(short.output).toBe('short')
  })

  test('wires the four hooks into the server export when options are provided', async () => {
    const module = await import('../src/index')
    const hooks = await module.default.server({} as never, {
      systemPromptRules: ['总是用简体中文回复'],
      permissionOverrides: { bash: 'deny' },
      webFetchAllowedDomains: ['example.com'],
      toolOutputCharLimits: { bash: 10 },
    })

    const systemOutput = { system: [] as string[] }
    await hooks['experimental.chat.system.transform']?.({ model: {} as never }, systemOutput)
    expect(systemOutput.system).toEqual(['总是用简体中文回复'])

    const permissionOutput = { status: 'ask' as const }
    await hooks['permission.ask']?.({ type: 'bash' } as never, permissionOutput)
    expect(permissionOutput.status).toBe('deny')
  })
})

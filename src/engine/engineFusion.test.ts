import { describe, expect, it } from 'vitest';
import {
  createKimiEngineConfig,
  createEngineLaunchEnvironment,
  resolveEngineFoundationPaths,
  resolveEngineFusionPaths,
  validateKimiEndpoint
} from './engineFusion.js';

describe('Engine fusion profile', () => {
  it('configures the engine through its Kimi-compatible provider without persisting the API key', () => {
    const config = createKimiEngineConfig({
      baseURL: 'https://api.moonshot.cn/v1/',
      modelID: 'kimi-k2.7-code'
    });

    expect(config.model).toBe('moonshotai-cn/kimi-k2.7-code');
    expect(config.provider['moonshotai-cn']).toMatchObject({
      api: 'https://api.moonshot.cn/v1',
      npm: '@ai-sdk/openai-compatible',
      env: ['KIMI_API_KEY'],
      options: { apiKey: '{env:KIMI_API_KEY}', baseURL: 'https://api.moonshot.cn/v1' }
    });
    expect(config.provider['moonshotai-cn'].models['kimi-k2.7-code']).toMatchObject({
      reasoning: true,
      tool_call: true
    });
    expect(config.plugin).toEqual(['{env:KIMI_RUNTIME_PLUGIN}']);
    expect(JSON.stringify(config)).not.toContain('secret-api-key');
  });

  it('keeps public read-only web research automatic while retaining prompts for side effects', () => {
    const config = createKimiEngineConfig({ modelID: 'kimi-k2.7-code' });

    expect(config.permission).toMatchObject({
      websearch: 'allow',
      webfetch: 'allow',
      bash: 'ask',
      edit: 'ask',
      task: 'allow'
    });
  });

  it('passes the API key only through the launched engine process environment', () => {
    expect(createEngineLaunchEnvironment({
      KIMI_API_KEY: 'secret-api-key',
      PATH: '/usr/bin'
    })).toMatchObject({
      KIMI_API_KEY: 'secret-api-key',
      OPENCODE_CLIENT: 'kimi-code-agent',
      OPENCODE_CONFIG_DIR: expect.stringContaining('Kimi Code Agent/engine')
    });
  });

  it('keeps the generated engine profile and state inside the Kimi application-support root', () => {
    expect(resolveEngineFusionPaths('/tmp/Kimi Code Agent')).toEqual({
      configDirectory: '/tmp/Kimi Code Agent/engine',
      configFile: '/tmp/Kimi Code Agent/engine/engine.json',
      stateDirectory: '/tmp/Kimi Code Agent/engine/state'
    });
  });

  it('uses the vendored engine plugin as the only native-adapter integration point', () => {
    expect(resolveEngineFoundationPaths('/tmp/kimi-agent')).toEqual({
      foundationDirectory: '/tmp/kimi-agent/vendor/engine',
      nativePluginFile: '/tmp/kimi-agent/vendor/engine/packages/kimi-code-agent-plugin/src/index.ts'
    });
  });

  it('rejects non-HTTPS and non-Kimi endpoints before the engine is started', () => {
    expect(() => validateKimiEndpoint('http://api.moonshot.cn/v1')).toThrow('HTTPS');
    expect(() => validateKimiEndpoint('https://example.com/v1')).toThrow('Kimi');
  });

  it('defaults small_model to the main model when no smallModelID is provided', () => {
    const config = createKimiEngineConfig({ modelID: 'kimi-k2.7-code' });

    expect(config.small_model).toBe('moonshotai-cn/kimi-k2.7-code');
    expect(config.provider['moonshotai-cn'].models['kimi-k2.7-code']).toBeDefined();
    expect(Object.keys(config.provider['moonshotai-cn'].models)).toEqual(['kimi-k2.7-code']);
  });

  it('routes small_model to a registered low-cost model when smallModelID is provided', () => {
    const config = createKimiEngineConfig({ modelID: 'kimi-k2.7-code', smallModelID: 'kimi-k2-lite' });

    expect(config.model).toBe('moonshotai-cn/kimi-k2.7-code');
    expect(config.small_model).toBe('moonshotai-cn/kimi-k2-lite');
    expect(config.provider['moonshotai-cn'].models['kimi-k2-lite']).toMatchObject({
      reasoning: true,
      tool_call: true
    });
  });

  it('ignores a smallModelID that is blank or identical to the main model', () => {
    expect(createKimiEngineConfig({ modelID: 'kimi-k2.7-code', smallModelID: '  ' }).small_model)
      .toBe('moonshotai-cn/kimi-k2.7-code');
    expect(createKimiEngineConfig({ modelID: 'kimi-k2.7-code', smallModelID: 'kimi-k2.7-code' }).small_model)
      .toBe('moonshotai-cn/kimi-k2.7-code');
  });
});

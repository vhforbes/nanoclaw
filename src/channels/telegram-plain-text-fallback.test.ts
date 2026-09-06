import { describe, expect, it, vi } from 'vitest';

import type { Adapter, AdapterPostableMessage, RawMessage } from 'chat';

import { installTelegramPlainTextFallback, isTelegramEntityParseError } from './telegram.js';

function result(id: string, threadId = 'telegram:42'): RawMessage<unknown> {
  return { id, threadId, raw: {} };
}

function adapterWithPost(postMessage: Adapter['postMessage']): Adapter {
  return { name: 'telegram-test', postMessage } as unknown as Adapter;
}

const parseError = new Error("Bad Request: can't parse entities: Can't find end of a URL at byte offset 1336");

describe('Telegram plain-text delivery fallback', () => {
  it('recognizes malformed URL/entity errors, including wrapped causes', () => {
    expect(isTelegramEntityParseError(parseError)).toBe(true);
    expect(isTelegramEntityParseError(new Error('send failed', { cause: parseError }))).toBe(true);
    expect(isTelegramEntityParseError(new Error('Network timeout'))).toBe(false);
  });

  it('retries once as raw text and returns the successful fallback result', async () => {
    const calls: AdapterPostableMessage[] = [];
    const postMessage = vi.fn(async (_threadId: string, message: AdapterPostableMessage) => {
      calls.push(message);
      if (calls.length === 1) throw parseError;
      return result('plain-ok');
    });
    const adapter = installTelegramPlainTextFallback(adapterWithPost(postMessage));

    const sent = await adapter.postMessage('telegram:42', {
      markdown: 'broken https://example.com/(',
      files: [{ data: Buffer.from('x'), filename: 'x.txt' }],
    });

    expect(sent.id).toBe('plain-ok');
    expect(postMessage).toHaveBeenCalledTimes(2);
    expect(calls[0]).toMatchObject({ markdown: 'broken https://example.com/(' });
    expect(calls[1]).toMatchObject({ raw: 'broken https://example.com/(' });
    expect(calls[1]).not.toHaveProperty('markdown');
    expect((calls[1] as { files?: unknown[] }).files).toHaveLength(1);
  });

  it('surfaces a failed plain-text fallback after exactly two sends', async () => {
    const fallbackError = new Error('Network timeout during fallback');
    const postMessage = vi
      .fn<Adapter['postMessage']>()
      .mockRejectedValueOnce(parseError)
      .mockRejectedValueOnce(fallbackError);
    const adapter = installTelegramPlainTextFallback(adapterWithPost(postMessage));

    await expect(adapter.postMessage('telegram:42', { markdown: 'broken https://example.com/(' })).rejects.toBe(
      fallbackError,
    );
    expect(postMessage).toHaveBeenCalledTimes(2);
  });

  it('does not duplicate sends for non-parse failures', async () => {
    const networkError = new Error('Network timeout');
    const postMessage = vi.fn<Adapter['postMessage']>().mockRejectedValue(networkError);
    const adapter = installTelegramPlainTextFallback(adapterWithPost(postMessage));

    await expect(adapter.postMessage('telegram:42', { markdown: 'hello' })).rejects.toBe(networkError);
    expect(postMessage).toHaveBeenCalledTimes(1);
  });
});

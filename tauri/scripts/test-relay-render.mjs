import { createServer } from 'vite';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

const server = await createServer({ server: { middlewareMode: true }, appType: 'custom' });
try {
  const { render } = await server.ssrLoadModule('svelte/server');
  const { default: Card } = await server.ssrLoadModule('/src/lib/components/ServiceCard.svelte');
  const fixture = JSON.parse(await readFile('src-tauri/tests/fixtures/mac-relay.json', 'utf8'));
  const display = Object.fromEntries(['plan', 'fiveHour', 'weekly', 'resetCountdown', 'updatedAt', 'balance', 'used', 'requestCount', 'models'].map(key => [key, true]));
  const snapshots = fixture.services.map(s => ({ ...s, config: { ...s.config, display, accent: '#4D6BFE' } }));
  const html = snapshots.map(snapshot => render(Card, { props: { snapshot } }).body);
  assert.match(html[0], /当前使用/);
  assert.match(html[0], /剩余 2 次/);
  assert.match(html[0], /到期时间未知/);
  assert.match(html[1], /刷新失败/);
  assert.match(html[2], /CNY/);
  assert.match(html[2], /USD/);
  assert.match(html[2], /12\.34/);
  assert.doesNotMatch(html[2], /历史消耗/);
  assert.match(html[3], /暂无|暂不提供额度查询/);
  assert.match(html[3], /Kimi-K3/);
  const empty = structuredClone(snapshots[3]);
  empty.status.usage.apiInfo.models = [];
  assert.match(render(Card, { props: { snapshot: empty } }).body, /暂无授权模型/);
  const unavailable = structuredClone(snapshots[0]);
  delete unavailable.status.usage.resetCredits.credits;
  assert.match(render(Card, { props: { snapshot: unavailable } }).body, /到期明细暂不可用/);
  const { cardSummary } = await server.ssrLoadModule('/src/lib/cardSummary.ts');
  const quotaStatus = { kind: 'ok', usage: { windows: [], apiInfo: { quotas: [
    { id: 'cloud_desktop', name: '云桌面／服务器', used: 125.5, remaining: 874.5, total: 1000, resetsAt: '' },
    { id: 'non_cloud', name: '非云端', used: 20, remaining: 0, total: 20, resetsAt: '' }
  ] } } };
  assert.match(cardSummary(quotaStatus, display), /云余874.5.*非云余0/);
  assert.match(cardSummary({ ...quotaStatus, kind: 'stale', error: 'offline' }, display), /^缓存/);
  assert.equal(cardSummary({ kind: 'loading' }, display), '加载中…');
  assert.equal(cardSummary({ kind: 'error', message: 'failure' }, display), '加载失败');
  assert.equal(cardSummary(quotaStatus, { ...display, balance: false, used: false }), '额度已隐藏');
  assert.match(cardSummary(snapshots[2].status, display), /CNY.*USD/);
  assert.equal(cardSummary({ kind: 'ok', usage: { windows: [], balance: { balance: 0.04, currency: '$' } } }, display), '余$0.04');
  assert.match(html[0], /aria-expanded="true"/);
  console.log('Relay card rendering checks passed');
} finally { await server.close(); }

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
  console.log('Relay card rendering checks passed');
} finally { await server.close(); }

<script lang="ts">
  import { onMount } from 'svelte';
  import ServiceCard from '$lib/components/ServiceCard.svelte';
  import type { ServiceSnapshot } from '$lib/types';

  let services = $state<ServiceSnapshot[]>([]);
  let capturedAt = $state<string | null>(null);
  let publishedAt = $state<string | null>(null);
  let loading = $state(false);
  let error = $state('');
  let mode = $state('sample');
  let now = $state(Date.now());
  const old = $derived(capturedAt ? now - Date.parse(capturedAt) > 15 * 60 * 1000 : true);
  const subscriptions = $derived(services.filter(s => s.config.category === 'subscription'));
  const providers = $derived(services.filter(s => s.config.category === 'apiUsage'));
  function date(value: string | null) { return value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '暂无数据'; }
  async function refresh() {
    if (loading) return;
    loading = true;
    error = '';
    try {
      const response = await fetch(`./usage.json?t=${Date.now()}`, { cache: 'no-store', signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw new Error('fetch');
      const snapshot = await response.json();
      if (snapshot.schemaVersion !== 1 || !Array.isArray(snapshot.services)) throw new Error('format');
      services = snapshot.services;
      capturedAt = snapshot.capturedAt;
      publishedAt = snapshot.publishedAt;
      mode = snapshot.mode;
    } catch { error = '暂时无法读取快照，请稍后重试。'; }
    finally { loading = false; now = Date.now(); }
  }
  onMount(() => {
    void refresh();
    const timer = setInterval(() => { now = Date.now(); void refresh(); }, 60000);
    return () => clearInterval(timer);
  });
</script>

<svelte:head><meta name="color-scheme" content="dark" /></svelte:head>
<main>
  <header>
    <div class="brand"><span class="mark" aria-hidden="true">◴</span><div><h1>TokenDeck</h1><p>AI 用量控制台</p></div></div>
    <a href="https://github.com/NBStarry/TokenDeck">GitHub ↗</a>
  </header>
  <div class="toolbar">
    <div><span class="badge">{mode === 'live' ? '真实用量快照' : '示例预览'}</span><span class="sub">只读 · 账号已匿名</span></div>
    <button onclick={refresh} disabled={loading}>{loading ? '读取中…' : '刷新快照'}</button>
  </div>
  <p class="time">数据更新于 {date(capturedAt)}{#if mode === 'live' && old}<span class="warning"> · 数据超过 15 分钟未更新</span>{/if}</p>
  {#if error}<p role="alert" class="warning">{error}{services.length ? ' 当前保留上次快照。' : ''}</p>{/if}
  {#if !services.length}<div class="empty">{loading ? '正在读取用量…' : '尚未发布用量快照'}</div>{/if}
  {#if subscriptions.length}
    <section aria-labelledby="subscriptions"><div class="section-title"><h2 id="subscriptions">订阅账号</h2><span>{subscriptions.length} 个账号</span></div>
      <div class="grid">{#each subscriptions as snapshot (snapshot.config.id)}<ServiceCard {snapshot} />{/each}</div>
    </section>
  {/if}
  {#if providers.length}
    <section aria-labelledby="providers"><div class="section-title"><h2 id="providers">API 渠道</h2><span>{providers.length} 个渠道</span></div>
      <div class="grid">{#each providers as snapshot (snapshot.config.id)}<ServiceCard {snapshot} />{/each}</div>
    </section>
  {/if}
  <footer>本机 TokenDeck 提供数据，网页读取已发布的快照。<br />本机离线时保留上次结果。发布于 {date(publishedAt)}</footer>
</main>

<style>
  :global(*) { box-sizing: border-box; }
  :global(body) { margin: 0; background: #111113; color: #ededf0; font: 16px/1.6 -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
  main { max-width: 1180px; margin: auto; padding: 40px 28px; }
  header, .brand, .toolbar, .section-title { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
  header { padding-bottom: 28px; border-bottom: 1px solid #303036; }
  .brand { justify-content: flex-start; }
  .mark { color: #b1a4ff; font-size: 48px; line-height: 1; }
  h1 { margin: 0; font-size: 26px; letter-spacing: -0.7px; }
  p { margin: 0; }
  .brand p, .sub, .time, footer, .section-title span { color: #a0a0aa; font-size: 14px; }
  a { color: #d9d5ff; text-decoration: none; font-size: 14px; }
  a:hover { text-decoration: underline; }
  .toolbar { margin: 26px 0 10px; flex-wrap: wrap; }
  .badge { border: 1px solid #494454; background: #25222e; border-radius: 6px; padding: 5px 9px; font-size: 14px; margin-right: 12px; display: inline-block; }
  button { background: #f0edf8; color: #222027; border: 0; border-radius: 8px; padding: 9px 16px; font: inherit; cursor: pointer; }
  button:disabled { opacity: .6; cursor: wait; }
  button:focus-visible, a:focus-visible { outline: 2px solid #b1a4ff; outline-offset: 4px; }
  .warning { color: #e6b863; }
  section { margin-top: 28px; }
  h2 { font-size: 16px; margin: 0; }
  .section-title { margin-bottom: 12px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(310px, 100%), 1fr)); gap: 16px; align-items: start; }
  .grid :global(.card) { min-height: 170px; }
  .grid :global(.card .sub-gray), .grid :global(.card .foot-gray), .grid :global(.provider small) { color: #aaaab2; }
  footer { border-top: 1px solid #303036; margin-top: 36px; padding-top: 20px; }
  .empty { padding: 48px 0; color: #aaa; }
  @media (max-width: 600px) { main { padding: 24px 16px; } .toolbar .sub { display: block; margin-top: 8px; } h1 { font-size: 23px; } }
</style>

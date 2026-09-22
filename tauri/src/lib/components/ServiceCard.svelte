<script lang="ts">
  import type { ServiceSnapshot, UsageWindow, Usage } from '$lib/types';
  import { barColor, hm, resetCountdown } from '$lib/theme';
  import ProgressBar from '$lib/components/ProgressBar.svelte';
  import BalanceBody from '$lib/components/BalanceBody.svelte';
  import ProviderBody from '$lib/components/ProviderBody.svelte';
  import ResetCreditsBody from '$lib/components/ResetCreditsBody.svelte';

  interface Props {
    snapshot: ServiceSnapshot;
  }
  let { snapshot }: Props = $props();

  const config = $derived(snapshot.config);
  const status = $derived(snapshot.status);
  const display = $derived(config.display);
  const accent = $derived(config.accent);

  // Extract plan from usage for ok/stale states
  const currentPlan = $derived(
    status.kind === 'ok' ? status.usage.plan :
    status.kind === 'stale' ? status.usage.plan :
    null
  );

  // Filter windows by display options
  function windowIsVisible(w: UsageWindow): boolean {
    if (w.label === '5 小时') return display.fiveHour;
    if (w.label === '周') return display.weekly;
    return true;
  }

  function visibleWindows(usage: Usage): UsageWindow[] {
    return usage.windows.filter(windowIsVisible);
  }
</script>

<!-- Card: radius 14, bg rgba(28,28,30,0.9), 1px rgba(255,255,255,0.08) border, padding 16/14 -->
<div class="card">
  <!-- Header: accent dot + title + plan badge -->
  <div class="header">
    <span class="dot" style="background-color: {accent}; box-shadow: 0 0 3px {accent};"></span>
    <span class="title">{config.title}</span>
    {#if display.plan && currentPlan}
      <span class="plan-badge">{currentPlan}</span>
    {/if}
  </div>

  {#if snapshot.isCurrentAccount}<span class="current-account">当前使用</span>{/if}

  <!-- Content by status.kind -->
  {#if status.kind === 'loading'}
    <div class="loading-row">
      <span class="spinner"></span>
      <span class="sub-gray" style="font-size: 12px;">加载中…</span>
    </div>

  {:else if status.kind === 'ok'}
    {#if status.usage.apiInfo}
      <ProviderBody info={status.usage.apiInfo} {accent} {display} />
    {:else if status.usage.balance}
      <BalanceBody info={status.usage.balance} {accent} {display} />
    {:else}
      {@const visible = visibleWindows(status.usage)}
      {#if visible.length === 0}
        <span class="sub-gray" style="font-size: 12px;">无可展示内容</span>
      {:else}
        <div class="windows">
          {#each visible as w}
            {@const pct = Math.min(100, Math.max(0, w.pct))}
            <div class="window-item">
              <div class="window-header">
                <span class="label-gray" style="font-size: 11px;">{w.label}</span>
                <span style="font-size: 11px; font-weight: 600; color: {barColor(pct)};">{Math.round(pct)}%</span>
              </div>
              <ProgressBar {pct} />
              {#if display.resetCountdown}
                {@const rc = resetCountdown(w.resetAt)}
                {#if rc}
                  <span class="sub-gray" style="font-size: 10px;">{rc}</span>
                {/if}
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    {/if}
    {#if status.usage.resetCredits}<ResetCreditsBody info={status.usage.resetCredits} />{/if}
    {#if display.updatedAt}
      <div class="footer-ok">
        <span class="foot-gray" style="font-size: 10px;">更新于 {hm(status.fetchedAt)}</span>
      </div>
    {/if}

  {:else if status.kind === 'stale'}
    {#if status.usage.apiInfo}
      <ProviderBody info={status.usage.apiInfo} {accent} {display} />
    {:else if status.usage.balance}
      <BalanceBody info={status.usage.balance} {accent} {display} />
    {:else}
      {@const visible = visibleWindows(status.usage)}
      {#if visible.length === 0}
        <span class="sub-gray" style="font-size: 12px;">无可展示内容</span>
      {:else}
        <div class="windows">
          {#each visible as w}
            {@const pct = Math.min(100, Math.max(0, w.pct))}
            <div class="window-item">
              <div class="window-header">
                <span class="label-gray" style="font-size: 11px;">{w.label}</span>
                <span style="font-size: 11px; font-weight: 600; color: {barColor(pct)};">{Math.round(pct)}%</span>
              </div>
              <ProgressBar {pct} />
              {#if display.resetCountdown}
                {@const rc = resetCountdown(w.resetAt)}
                {#if rc}
                  <span class="sub-gray" style="font-size: 10px;">{rc}</span>
                {/if}
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    {/if}
    {#if status.usage.resetCredits}<ResetCreditsBody info={status.usage.resetCredits} />{/if}
    <div class="footer-stale">
      <span style="font-size: 10px; color: #D29922; text-align: right;">
        ⚠ 刷新失败,显示上次结果{status.cachedAt ? ' · ' + hm(status.cachedAt) : ''}
      </span>
    </div>

  {:else if status.kind === 'error'}
    <span style="font-size: 12px; color: #F85149; line-height: 1.4;">{status.message}</span>
  {/if}
</div>

<style>
.current-account { color: #10A37F; font-size: 11px; margin-bottom: 8px; }
.title { overflow-wrap: anywhere; }
.card {
  display: flex;
  flex-direction: column;
  padding: 14px 16px;
  background: rgba(28, 28, 30, 0.9);
  border-radius: 14px;
  border: 1px solid rgba(255, 255, 255, 0.08);
}

.header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding-bottom: 12px;
}

.dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  flex-shrink: 0;
}

.title {
  font-size: 14px;
  font-weight: 600;
  color: white;
  flex: 1;
}

.plan-badge {
  font-size: 10px;
  font-weight: 600;
  color: white;
  padding: 2px 7px;
  background: black;
  border-radius: 9999px;
}

.loading-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 0;
}

/* Simple CSS spinner approximating SwiftUI ProgressView */
.spinner {
  display: inline-block;
  width: 12px;
  height: 12px;
  border: 2px solid rgba(255, 255, 255, 0.2);
  border-top-color: rgba(255, 255, 255, 0.7);
  border-radius: 50%;
  animation: spin 0.8s linear infinite;
}

@keyframes spin {
  to { transform: rotate(360deg); }
}

.windows {
  display: flex;
  flex-direction: column;
  gap: 11px;
}

.window-item {
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.window-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.footer-ok {
  display: flex;
  justify-content: flex-end;
  padding-top: 8px;
}

.footer-stale {
  display: flex;
  justify-content: flex-end;
  padding-top: 8px;
}

.label-gray { color: #D8D8DA; }
.sub-gray   { color: #8E8E93; }
.foot-gray  { color: #6E6E73; }
</style>

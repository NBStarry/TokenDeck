<script lang="ts">
  import type { ResetCredits } from '$lib/types';
  let { info }: { info: ResetCredits } = $props();
  function expiry(raw: string | null): string {
    const date = raw ? new Date(raw) : null;
    return date && Number.isFinite(date.getTime())
      ? date.toLocaleString(undefined, { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }) + ' 到期'
      : '到期时间未知';
  }
</script>
<div class="credits">
  <strong>额度重置机会 · 剩余 {info.availableCount} 次</strong>
  {#if info.applicableCount != null && info.applicableCount !== info.availableCount}
    <span>当前套餐可用 {info.applicableCount} 次</span>
  {/if}
  {#if info.credits}
    {#each info.credits as credit, i}
      <span>第 {i + 1} 次 · {expiry(credit.expiresAt)}{credit.applicable ? '' : ' · 当前套餐不适用'}</span>
    {/each}
    {#if info.credits.length !== info.availableCount}<span>部分到期明细暂不可用</span>{/if}
  {:else if info.availableCount > 0}<span>到期明细暂不可用，请稍后刷新</span>{/if}
</div>
<style>
.credits { display: flex; flex-direction: column; gap: 5px; margin-top: 12px; font-size: 11px; color: #8E8E93; overflow-wrap: anywhere; }
strong { color: #D8D8DA; }
</style>

<script lang="ts">
  import type { APIInfo, ServiceDisplayOptions } from '$lib/types';
  let { info, accent, display }: { info: APIInfo; accent: string; display: ServiceDisplayOptions } = $props();
</script>
<div class="provider">
  {#if info.balances}
    {#if display.balance}
      {#each info.balances as balance}
        <div class="balance">
          <span>总余额 · {balance.currency}</span>
          <strong style:color={accent}>{balance.total.toFixed(2)}</strong>
          <small>充值余额 {balance.toppedUp.toFixed(2)} · 赠金余额 {balance.granted.toFixed(2)}</small>
        </div>
      {/each}
    {/if}
    {#if info.isAvailable === false}<span class="warning">余额不足，当前不可调用</span>
    {:else if !display.balance}<small>余额展示已关闭</small>{/if}
  {/if}
  {#if info.models}
    <span style:color={accent}>密钥查询正常</span>
    <small>暂不提供额度查询</small>
    {#if display.models}
      {#if info.models.length === 0}<small>暂无授权模型</small>
      {:else}
        <details><summary>授权模型 · {info.models.length}</summary>
          <div class="models">{#each info.models as model}<div>{model}</div>{/each}</div>
        </details>
      {/if}
    {/if}
  {/if}
</div>
<style>
.provider, .balance { display: flex; flex-direction: column; gap: 7px; font-size: 12px; color: #D8D8DA; }
.balance strong { font-size: 24px; }
small { color: #8E8E93; font-size: 11px; overflow-wrap: anywhere; }
.warning { color: #D29922; }
summary { cursor: pointer; padding: 8px 0; }
.models { max-height: 180px; overflow-y: auto; overflow-wrap: anywhere; line-height: 1.8; }
</style>

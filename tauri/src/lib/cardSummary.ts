import type { ServiceStatus, ServiceDisplayOptions, Usage } from './types';

export function cardSummary(status: ServiceStatus, display: ServiceDisplayOptions): string {
  if (status.kind === 'loading') return '加载中…';
  if (status.kind === 'error') return '加载失败';
  return (status.kind === 'stale' ? '缓存 · ' : '') + usageSummary(status.usage, display);
}

function usageSummary(usage: Usage, display: ServiceDisplayOptions): string {
  const number = (value: number) => value.toLocaleString(undefined, { maximumFractionDigits: 1, notation: value >= 10000 ? 'compact' : 'standard' });
  const money = (value: number) => value.toFixed(2);
  const info = usage.apiInfo;
  if (info?.quotas) {
    const parts = info.quotas.flatMap(q => {
      const name = q.id === 'cloud_desktop' ? '云' : q.id === 'non_cloud' ? '非云' : q.name;
      return display.balance ? [name + '余' + number(q.remaining)] : display.used ? [name + '用' + number(q.used)] : [];
    });
    return parts.join(' / ') || '额度已隐藏';
  }
  if (info?.balances) {
    const amount = display.balance ? info.balances.map(b => b.currency + ' ' + money(b.total)).join(' / ') : '余额已隐藏';
    return (info.isAvailable === false ? '不可用 · ' : '') + (amount || '余额未知');
  }
  if (info?.models) return '暂无额度查询';
  if (usage.balance) return display.balance ? '余' + usage.balance.currency + money(usage.balance.balance) : '余额已隐藏';
  return usage.windows.filter(w => w.label === '5 小时' ? display.fiveHour : w.label === '周' ? display.weekly : true)
    .map(w => w.label + ' ' + number(Math.min(100, Math.max(0, w.pct))) + '%').join(' / ') || '无可展示内容';
}

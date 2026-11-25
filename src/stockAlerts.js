const asDay = value => String(value || '').slice(0, 10);
const daysBetween = (from, to) => Math.round((Date.parse(`${asDay(to)}T00:00:00Z`) - Date.parse(`${asDay(from)}T00:00:00Z`)) / 86400000);

export function buildStockAlerts(products, today, windowDays = 45) {
  const expiredBatches = (products || []).flatMap(product =>
    (product.batches || [])
      .filter(batch => Number(batch.units) > 0 && batch.expiry_date && asDay(batch.expiry_date) < today)
      .map(batch => ({ ...batch, product, days: daysBetween(batch.expiry_date, today) }))
  ).sort((a, b) => asDay(b.expiry_date).localeCompare(asDay(a.expiry_date)));

  const expiredUnitCount = expiredBatches.reduce((sum, batch) => sum + Number(batch.units || 0), 0);
  const expiredStockValue = expiredBatches.reduce((sum, batch) => sum + Number(batch.units || 0) * Number(batch.product.selling_price ?? batch.product.mrp ?? 0), 0);
  const expiredProductCount = new Set(expiredBatches.map(batch => batch.product.id)).size;

  const expiringRaw = (products || []).flatMap(product =>
    (product.batches || []).map(batch => ({
      ...batch,
      product,
      days: batch.expiry_date ? daysBetween(today, batch.expiry_date) : Infinity,
    }))
  ).filter(batch => Number(batch.units) > 0 && batch.expiry_date && batch.days >= 0 && batch.days <= windowDays);

  const expiring = [...expiringRaw.reduce((groups, batch) => {
    const key = `${batch.product.id}|${asDay(batch.expiry_date)}`;
    const row = groups.get(key) || { ...batch, units: 0, value: 0, batchIds: [], discounted: true };
    row.units += Number(batch.units || 0);
    row.value += Number(batch.units || 0) * Number(batch.cost_price ?? batch.product.cost_price ?? batch.product.selling_price ?? batch.product.mrp ?? 0);
    row.batchIds.push(batch.id);
    row.discounted = row.discounted && !!batch.discounted;
    groups.set(key, row);
    return groups;
  }, new Map()).values()].sort((a, b) => a.days - b.days || asDay(a.expiry_date).localeCompare(asDay(b.expiry_date)));

  const expiringSoonValue = expiring.reduce((sum, batch) => sum + batch.value, 0);

  const checkDateBatches = (products || []).flatMap(product =>
    (product.batches || [])
      .filter(batch => Number(batch.units) > 0 && (!batch.mfg_date || !batch.expiry_date))
      .map(batch => ({ ...batch, product }))
  ).sort((a, b) => (a.product.name || '').localeCompare(b.product.name || '') || String(a.id).localeCompare(String(b.id)));

  return { expiredBatches, expiredUnitCount, expiredStockValue, expiredProductCount, expiring, expiringSoonValue, checkDateBatches };
}

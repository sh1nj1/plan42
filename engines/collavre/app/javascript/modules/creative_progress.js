export function progressBaselineValueFrom(originalProgress) {
  const numeric = Number(originalProgress);
  if (Number.isNaN(numeric)) return 0;
  return numeric >= 1 ? 1 : 0;
}

export function progressValueChangedFrom(originalProgress, checked) {
  const baseline = progressBaselineValueFrom(originalProgress);
  const current = checked ? 1 : 0;
  return current !== baseline;
}

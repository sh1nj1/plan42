export function isProgressComplete(value) {
  const numeric = Number(value);
  return !Number.isNaN(numeric) && numeric >= 1;
}

export function progressBaselineValueFrom(originalProgress) {
  return isProgressComplete(originalProgress) ? 1 : 0;
}

export function progressValueChangedFrom(originalProgress, checked) {
  const baseline = progressBaselineValueFrom(originalProgress);
  const current = checked ? 1 : 0;
  return current !== baseline;
}

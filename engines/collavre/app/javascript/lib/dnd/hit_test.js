export const DEFAULT_CHILD_ZONE_RATIO = 0.3;
export const DEFAULT_HYSTERESIS_RATIO = 0.12;
export const DEFAULT_MIN_HYSTERESIS = 12;

export function getVerticalDropPosition({
  clientY,
  rect,
  previousPosition = null,
  childZoneRatio = DEFAULT_CHILD_ZONE_RATIO,
  hysteresisRatio = DEFAULT_HYSTERESIS_RATIO,
  minHysteresis = DEFAULT_MIN_HYSTERESIS,
}) {
  if (!rect || !Number.isFinite(clientY)) return null;

  const height = Number(rect.height);
  const top = Number(rect.top);
  if (!Number.isFinite(height) || height <= 0 || !Number.isFinite(top)) return null;

  const relativeY = clientY - top;
  const hysteresis = Math.max(minHysteresis, height * hysteresisRatio);
  let topLimit = height * childZoneRatio;
  let bottomLimit = height * (1 - childZoneRatio);

  if (previousPosition === 'up') {
    topLimit += hysteresis;
  } else if (previousPosition === 'child') {
    topLimit -= hysteresis;
    bottomLimit += hysteresis;
  } else if (previousPosition === 'down') {
    bottomLimit -= hysteresis;
  }

  if (relativeY < topLimit) return 'up';
  if (relativeY > bottomLimit) return 'down';
  return 'child';
}

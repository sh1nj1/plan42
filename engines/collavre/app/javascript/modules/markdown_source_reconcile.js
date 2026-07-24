// Reconcile a server-rewritten markdown source with the current textarea value
// when the user typed during the save. The server's rewrite is a pure
// data: URI -> blob path substitution on what we sent (`savedContent`).
// If every data: URI we sent is still present in `currentValue`, apply the
// same substitutions there and return the merged value; otherwise return null.
export function reconcileMarkdownSource(savedContent, rewritten, currentValue) {
  if (typeof savedContent !== 'string' || typeof rewritten !== 'string'
      || typeof currentValue !== 'string') return null;
  if (rewritten === savedContent) return null;
  if (currentValue === savedContent) return rewritten;

  const dataUriRegex = /data:image\/[^\s)>"'`\]]+/g;
  const matches = [];
  let m;
  while ((m = dataUriRegex.exec(savedContent)) !== null) {
    matches.push({ uri: m[0], start: m.index, end: m.index + m[0].length });
  }
  if (matches.length === 0) return null;

  const pairs = [];
  let savedPos = 0;
  let rewrittenPos = 0;
  for (let i = 0; i < matches.length; i++) {
    const match = matches[i];
    const textLen = match.start - savedPos;
    if (rewritten.slice(rewrittenPos, rewrittenPos + textLen)
        !== savedContent.slice(savedPos, match.start)) return null;
    rewrittenPos += textLen;
    savedPos = match.end;

    const nextStart = (i + 1 < matches.length) ? matches[i + 1].start : savedContent.length;
    const tail = savedContent.slice(savedPos, nextStart);
    let blobEnd;
    if (tail.length === 0) {
      blobEnd = rewritten.length;
    } else {
      blobEnd = rewritten.indexOf(tail, rewrittenPos);
      if (blobEnd === -1) return null;
    }
    pairs.push({ from: match.uri, to: rewritten.slice(rewrittenPos, blobEnd) });
    rewrittenPos = blobEnd;
  }
  if (rewritten.slice(rewrittenPos) !== savedContent.slice(savedPos)) return null;

  let result = currentValue;
  for (const pair of pairs) {
    if (pair.from === pair.to) continue;
    const idx = result.indexOf(pair.from);
    if (idx === -1) return null;
    result = result.slice(0, idx) + pair.to + result.slice(idx + pair.from.length);
  }
  return result;
}

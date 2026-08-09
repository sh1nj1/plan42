const NAMED_ENTITIES = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  "#39": "'",
  nbsp: " ",
};

const ENTITY_PATTERN = /&(amp|lt|gt|quot|#39|nbsp|#\d+|#x[0-9a-fA-F]+);/g;

export function decodeHtmlEntities(text) {
  if (!text) return text;

  return text.replace(ENTITY_PATTERN, (match, entity) => {
    if (Object.hasOwn(NAMED_ENTITIES, entity)) return NAMED_ENTITIES[entity];

    const codePoint = entity.startsWith("#x")
      ? Number.parseInt(entity.slice(2), 16)
      : Number.parseInt(entity.slice(1), 10);

    return codePoint <= 0x10ffff ? String.fromCodePoint(codePoint) : match;
  });
}

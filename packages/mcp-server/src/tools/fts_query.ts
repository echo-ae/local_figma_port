export function toFtsLiteralQuery(input: string): string {
  const terms = input
    .trim()
    .split(/\s+/)
    .map((term) => term.trim())
    .filter(Boolean);

  if (terms.length === 0) {
    return '""';
  }

  return terms.map((term) => `"${term.replace(/"/g, '""')}"`).join(" ");
}

export function normalizeSearchText(input: string): string {
  return input.trim().toLowerCase().replace(/\s+/g, " ");
}

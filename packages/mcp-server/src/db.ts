import { execFileSync } from "node:child_process";

const SQLITE_PATH = process.env.SQLITE_PATH ?? "/data/design_store.sqlite";
const SQLITE3_BIN = process.env.SQLITE3_BIN ?? "sqlite3";

function sqlLiteral(value: unknown): string {
  if (value === null || value === undefined) {
    return "NULL";
  }
  if (typeof value === "number") {
    return Number.isFinite(value) ? String(value) : "NULL";
  }
  if (typeof value === "boolean") {
    return value ? "1" : "0";
  }
  const s = String(value).replace(/'/g, "''");
  return `'${s}'`;
}

function bind(sql: string, params: unknown[] = []): string {
  let i = 0;
  return sql.replace(/\?/g, () => sqlLiteral(params[i++]));
}

export function query<T = Record<string, unknown>>(sql: string, params: unknown[] = []): T[] {
  const rendered = bind(sql, params);
  const out = execFileSync(SQLITE3_BIN, ["-json", SQLITE_PATH, rendered], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
  if (!out) return [];
  return JSON.parse(out) as T[];
}

export function one<T = Record<string, unknown>>(sql: string, params: unknown[] = []): T | null {
  const rows = query<T>(`${sql} LIMIT 1`, params);
  return rows.length ? rows[0] : null;
}

export function execute(sql: string, params: unknown[] = []): void {
  const rendered = bind(sql, params);
  execFileSync(SQLITE3_BIN, [SQLITE_PATH, rendered], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

export { SQLITE_PATH, SQLITE3_BIN };

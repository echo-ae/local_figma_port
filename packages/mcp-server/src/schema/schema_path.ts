import fs from "node:fs";
import path from "node:path";

const TOOL_SCHEMA_RELATIVE_PATH = ["schemas", "mcp-tools.v1.schema.json"] as const;

export function resolveToolSchemaPath(fromDir: string): string {
  const candidateDirs = [
    path.resolve(fromDir, ".."),
    path.resolve(fromDir, "..", ".."),
    path.resolve(fromDir, "..", "..", ".."),
    path.resolve(fromDir, "..", "..", "..", ".."),
  ];

  for (const dir of candidateDirs) {
    const candidate = path.join(dir, ...TOOL_SCHEMA_RELATIVE_PATH);
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return path.join(candidateDirs[0], ...TOOL_SCHEMA_RELATIVE_PATH);
}

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv from "ajv";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../../..");
const schemaPath = path.join(repoRoot, "schemas", "mcp-tools.v1.schema.json");

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const AjvCtor: any = (Ajv as any)?.default ?? (Ajv as any);
const ajv = new AjvCtor({ allErrors: true, strict: false });

const toolSchemas = (schema?.properties?.tools?.properties ?? {}) as Record<string, any>;
type ValidatorFn = ((data: unknown) => boolean) & { errors?: unknown };
const validators = new Map<string, { input: ValidatorFn; output: ValidatorFn }>();

for (const [tool, def] of Object.entries(toolSchemas)) {
  validators.set(tool, {
    input: ajv.compile((def as any).properties.input),
    output: ajv.compile((def as any).properties.output),
  });
}

function explain(errors: unknown): string {
  if (!Array.isArray(errors)) return "unknown validation error";
  return errors
    .map((e: any) => `${e.instancePath || "/"} ${e.message || "invalid"}`)
    .join("; ");
}

export function validateToolInput(tool: string, input: unknown): void {
  const v = validators.get(tool);
  if (!v) throw new Error(`Unknown tool: ${tool}`);
  if (!v.input(input)) {
    throw new Error(`Invalid input for ${tool}: ${explain(v.input.errors)}`);
  }
}

export function validateToolOutput(tool: string, output: unknown): void {
  const v = validators.get(tool);
  if (!v) throw new Error(`Unknown tool: ${tool}`);
  if (!v.output(output)) {
    throw new Error(`Invalid output for ${tool}: ${explain(v.output.errors)}`);
  }
}

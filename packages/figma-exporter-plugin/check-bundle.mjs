import fs from "node:fs";
import path from "node:path";

const bundlePath = path.join(process.cwd(), "dist", "main.js");

if (!fs.existsSync(bundlePath)) {
  console.error("[check-bundle] missing dist/main.js");
  process.exit(1);
}

const source = fs.readFileSync(bundlePath, "utf8");
if (!source.includes("figma.showUI") || !source.includes("figma.ui.onmessage")) {
  console.error("[check-bundle] dist/main.js does not look like a bundled Figma plugin entry");
  process.exit(1);
}

console.log("[check-bundle] bundle looks valid");

import {
  type CoverageChecklistInput,
  synthesizeCoverageChecklist,
} from "./checklist_synthesis.js";

export function buildCoverageChecklist(input: CoverageChecklistInput) {
  return synthesizeCoverageChecklist(input);
}

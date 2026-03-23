import { type ResolveTargetInput, resolveTargetCandidates } from "./target_resolution.js";

function candidateKey(candidate: {
  targetType: string;
  targetId: string;
  nodeId: string | null;
  pageId: string | null;
}) {
  if (candidate.nodeId) return `node:${candidate.nodeId}`;
  if (candidate.pageId && candidate.targetType === "page") return `page:${candidate.pageId}`;
  return `${candidate.targetType}:${candidate.targetId}`;
}

function targetPriority(targetType: string): number {
  if (targetType === "selection") return 3;
  if (targetType === "node") return 2;
  return 1;
}

function dedupePreferredScopes<T extends {
  targetType: string;
  targetId: string;
  nodeId: string | null;
  pageId: string | null;
  matchReason: string[];
  confidence: number;
  previewUri?: string;
  previewFileUri?: string;
}>(candidates: T[]): T[] {
  const merged = new Map<string, T>();

  for (const candidate of candidates) {
    const key = candidateKey(candidate);
    const existing = merged.get(key);
    if (!existing) {
      merged.set(key, { ...candidate, matchReason: [...candidate.matchReason] });
      continue;
    }

    const preferCandidate =
      targetPriority(candidate.targetType) > targetPriority(existing.targetType) ||
      (
        targetPriority(candidate.targetType) === targetPriority(existing.targetType) &&
        candidate.confidence > existing.confidence
      );

    if (preferCandidate) {
      merged.set(key, {
        ...candidate,
        matchReason: [...new Set([...existing.matchReason, ...candidate.matchReason])],
        previewUri: candidate.previewUri ?? existing.previewUri,
        previewFileUri: candidate.previewFileUri ?? existing.previewFileUri,
      });
    } else {
      existing.matchReason = [...new Set([...existing.matchReason, ...candidate.matchReason])];
      existing.previewUri = existing.previewUri ?? candidate.previewUri;
      existing.previewFileUri = existing.previewFileUri ?? candidate.previewFileUri;
    }
  }

  return [...merged.values()].sort((left, right) => right.confidence - left.confidence);
}

export function resolveTarget(input: ResolveTargetInput) {
  const candidates = dedupePreferredScopes(resolveTargetCandidates(input));
  const top = candidates[0];
  const second = candidates[1];
  const ambiguous =
    candidates.length > 1 &&
    !!top &&
    !!second &&
    second.confidence >= 0.8 &&
    top.confidence - second.confidence <= 0.08;

  return {
    query: input.query,
    candidates,
    ambiguous,
  };
}

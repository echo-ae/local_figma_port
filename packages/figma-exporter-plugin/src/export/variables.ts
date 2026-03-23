export function exportVariables(): unknown {
  const collections = figma.variables.getLocalVariableCollections();
  const variables: Array<{
    id: string;
    key: string;
    name: string;
    resolvedType: VariableResolvedDataType;
    valuesByMode: Record<string, VariableValue>;
    scopes: VariableScope[];
  }> = [];

  for (const c of collections) {
    for (const id of c.variableIds) {
      const v = figma.variables.getVariableById(id);
      if (!v) continue;
      variables.push({
        id: v.id,
        key: `var:${v.name}`,
        name: v.name,
        resolvedType: v.resolvedType,
        valuesByMode: v.valuesByMode,
        scopes: v.scopes,
      });
    }
  }

  return {
    collections: collections.map((c) => ({
      id: c.id,
      name: c.name,
      modes: c.modes,
      variableIds: c.variableIds,
    })),
    variables,
  };
}

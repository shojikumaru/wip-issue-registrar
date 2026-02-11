#!/usr/bin/env bash
# DAG operations: cycle detection + topological sort (FR-002)
# Usage: source this file, then call dag_validate or dag_topo_sort

# Detect cycles in dependencyDAG using DFS
# Args: $1 = issue-packet.json path
# Returns: 0 = no cycles, 1 = cycle found (prints cycle path to stderr)
dag_validate() {
  local packet="$1"

  # Extract edges as "FROM TO" lines
  local edges
  edges=$(jq -r '.dependencyDAG.edges[]? | "\(.[0]) \(.[1])"' "$packet" 2>/dev/null)

  if [[ -z "$edges" ]]; then
    return 0  # No edges = no cycles
  fi

  # Build adjacency list and detect cycle with DFS
  # Using a Python one-liner since bash DFS is painful
  python3 -c "
import sys, json

with open('$packet') as f:
    data = json.load(f)

edges = data.get('dependencyDAG', {}).get('edges', [])
nodes = set(data.get('dependencyDAG', {}).get('nodes', []))

# Build adjacency list
adj = {}
for e in edges:
    adj.setdefault(e[0], []).append(e[1])
    nodes.add(e[0])
    nodes.add(e[1])

# DFS cycle detection
WHITE, GRAY, BLACK = 0, 1, 2
color = {n: WHITE for n in nodes}
parent = {}
cycle_path = []

def dfs(u):
    color[u] = GRAY
    for v in adj.get(u, []):
        if color.get(v, WHITE) == GRAY:
            # Found cycle - reconstruct path
            path = [v, u]
            cur = u
            while cur != v and cur in parent:
                cur = parent[cur]
                path.append(cur)
            path.reverse()
            print(' -> '.join(path), file=sys.stderr)
            return True
        if color.get(v, WHITE) == WHITE:
            parent[v] = u
            if dfs(v):
                return True
    color[u] = BLACK
    return False

for node in sorted(nodes):
    if color.get(node, WHITE) == WHITE:
        if dfs(node):
            sys.exit(1)
sys.exit(0)
" 2>&1
  return $?
}

# Topological sort of dependencyDAG
# Args: $1 = issue-packet.json path
# Output: sorted node IDs, one per line (dependencies first)
dag_topo_sort() {
  local packet="$1"

  python3 -c "
import sys, json

with open('$packet') as f:
    data = json.load(f)

edges = data.get('dependencyDAG', {}).get('edges', [])
nodes = list(data.get('dependencyDAG', {}).get('nodes', []))

# Build adjacency list and in-degree
adj = {}
in_deg = {n: 0 for n in nodes}
for e in edges:
    adj.setdefault(e[0], []).append(e[1])
    in_deg.setdefault(e[1], 0)
    in_deg[e[1]] = in_deg.get(e[1], 0) + 1
    if e[0] not in in_deg:
        in_deg[e[0]] = 0

# Kahn's algorithm
queue = sorted([n for n in in_deg if in_deg[n] == 0])
result = []
while queue:
    u = queue.pop(0)
    result.append(u)
    for v in sorted(adj.get(u, [])):
        in_deg[v] -= 1
        if in_deg[v] == 0:
            queue.append(v)

# Check for remaining (cycle)
if len(result) != len(in_deg):
    remaining = set(in_deg.keys()) - set(result)
    print('ERROR: cycle detected among: ' + ', '.join(sorted(remaining)), file=sys.stderr)
    sys.exit(1)

for n in result:
    print(n)
"
  return $?
}

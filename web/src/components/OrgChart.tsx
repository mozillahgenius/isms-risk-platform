import type { DepartmentNode, MembershipRow } from '@/lib/organizationRegister';

type TreeNode = DepartmentNode & { children: TreeNode[] };

// 現状は部門登録がINSERTのみ(親を後から差し替える編集機能は無い)ため、純粋な
// 循環は通常の操作では作れない。ただし将来の編集機能やDB直接操作に備えて、
// 循環参照・過剰な深さは無言で消さず明示する(Codexレビュー2026-09-03指摘)。
const MAX_DEPTH = 20;

function buildTree(departments: DepartmentNode[]): { roots: TreeNode[]; excluded: DepartmentNode[] } {
  const nodes = new Map<string, TreeNode>();
  for (const d of departments) nodes.set(d.id, { ...d, children: [] });
  const roots: TreeNode[] = [];
  for (const d of departments) {
    const node = nodes.get(d.id)!;
    if (d.parent_id && nodes.has(d.parent_id)) {
      nodes.get(d.parent_id)!.children.push(node);
    } else {
      roots.push(node);
    }
  }
  // 循環に巻き込まれた部門は必ず親を持つのでrootsに入らず、この構造では
  // どこからも辿れない。rootsからの到達集合を計算し、外れたものを
  // excludedとして表示側へ渡す。深さ上限を超えた先も同様に切り捨てる。
  const reached = new Set<string>();
  const walk = (node: TreeNode, depth: number) => {
    reached.add(node.id);
    if (depth >= MAX_DEPTH) {
      node.children = [];
      return;
    }
    for (const child of node.children) walk(child, depth + 1);
  };
  for (const root of roots) walk(root, 0);
  const excluded = departments.filter((d) => !reached.has(d.id));
  return { roots, excluded };
}

function DeptNode({ node, membersByDept }: { node: TreeNode; membersByDept: Map<string, MembershipRow[]> }) {
  const members = membersByDept.get(node.id) ?? [];
  return (
    <li className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2 rounded-[var(--radius)] border border-[var(--border)] bg-[var(--surface-2)] p-2">
        <span className="font-medium text-[13px]">{node.name}</span>
        <span className="text-[12px] text-[var(--muted)]">
          {node.owner_name ? `責任者(マネージャー): ${node.owner_name}` : '責任者(マネージャー)未設定'}
        </span>
        <span className="text-[12px] text-[var(--muted)]">在籍 {node.member_count}名</span>
        {members.length > 0 && (
          <div className="flex flex-wrap gap-1">
            {members.map((m) => (
              <span key={m.id} className="badge badge-note whitespace-nowrap">
                {m.role_name ?? m.role_key}: {m.display_name}({m.granted_at})
              </span>
            ))}
          </div>
        )}
      </div>
      {node.children.length > 0 && (
        <ul className="ml-5 flex flex-col gap-2 border-l border-[var(--border)] pl-4">
          {node.children.map((child) => (
            <DeptNode key={child.id} node={child} membersByDept={membersByDept} />
          ))}
        </ul>
      )}
    </li>
  );
}

function MemberBadges({ members }: { members: MembershipRow[] }) {
  return (
    <div className="mt-1 flex flex-wrap gap-1">
      {members.map((m) => (
        <span key={m.id} className="badge badge-note whitespace-nowrap">
          {m.role_name ?? m.role_key}: {m.display_name}({m.granted_at})
        </span>
      ))}
    </div>
  );
}

export function OrgChart({ departments, memberships }: { departments: DepartmentNode[]; memberships: MembershipRow[] }) {
  const { roots: tree, excluded } = buildTree(departments);
  const excludedIds = new Set(excluded.map((d) => d.id));
  const membersByDept = new Map<string, MembershipRow[]>();
  for (const m of memberships) {
    if (!m.department_id) continue;
    const list = membersByDept.get(m.department_id) ?? [];
    list.push(m);
    membersByDept.set(m.department_id, list);
  }
  const unassigned = memberships.filter((m) => !m.department_id);
  // 循環参照・深さ超過でツリーから除外された部門に所属するメンバーは、
  // DeptNodeとしてもunassignedとしても描画されず消えてしまっていた
  // (Codexレビュー2026-09-03 9回目指摘)。所属先が表示できない以上、
  // 「部門未設定」枠に合流させて可視性だけは確保する。
  const excludedMembers = memberships.filter((m) => m.department_id && excludedIds.has(m.department_id));
  return (
    <div className="flex flex-col gap-4">
      {departments.length === 0 ? (
        <p className="text-[13px] text-[var(--muted)]">部門が登録されていません。</p>
      ) : (
        <ul className="flex flex-col gap-2">
          {tree.map((node) => (
            <DeptNode key={node.id} node={node} membersByDept={membersByDept} />
          ))}
        </ul>
      )}
      {excluded.length > 0 && (
        <div className="card border-[var(--danger)] bg-[var(--danger-weak)] p-3" role="alert">
          <p className="text-[12px] font-medium text-[var(--badge-danger-fg)]">
            循環参照または階層が深すぎるため表示できない部門があります: {excluded.map((d) => d.name).join('、')}
          </p>
        </div>
      )}
      {(unassigned.length > 0 || excludedMembers.length > 0) && (
        <div>
          <p className="text-[12px] font-medium text-[var(--muted)]">部門未設定のメンバー</p>
          <MemberBadges members={unassigned} />
          {excludedMembers.length > 0 && (
            <>
              <p className="mt-2 text-[12px] font-medium text-[var(--muted)]">
                表示できない部門に所属するメンバー
              </p>
              <MemberBadges members={excludedMembers} />
            </>
          )}
        </div>
      )}
    </div>
  );
}

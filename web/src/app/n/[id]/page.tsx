import { notFound, redirect } from 'next/navigation';
import { decodeNodeId } from '@/lib/nodeid';
import { destinationOf } from '@/lib/nodeDestination';

// 図のノードをクリックしたときの行き先を決めるだけのページ。
// 判断そのものは lib/nodeDestination.ts（純関数・テスト対象）に置く。

export const dynamic = 'force-dynamic';

export default async function ResolveNode({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const decoded = decodeNodeId(id);
  if (!decoded) notFound();

  const to = destinationOf(decoded.type, decoded.key);
  if (!to) notFound();

  redirect(to);
}

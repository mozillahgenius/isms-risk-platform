import { notFound, redirect } from 'next/navigation';
import { decodeNodeId } from '@/lib/nodeid';
import { destinationOf } from '@/lib/nodeDestination';

// A page that only decides where to go when a node in the diagram is clicked.
// The decision itself lives in lib/nodeDestination.ts (pure function, under test).

export const dynamic = 'force-dynamic';

export default async function ResolveNode({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const decoded = decodeNodeId(id);
  if (!decoded) notFound();

  const to = destinationOf(decoded.type, decoded.key);
  if (!to) notFound();

  redirect(to);
}

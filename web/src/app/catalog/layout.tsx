import { CatalogTabs } from '@/components/CatalogTabs';

// Catalog pages are one level down, so the sub-navigation is rendered here.
// Placing it in the layout shows where you are not only on lists but also on detail pages (individual controls, policies, risks).
export default function CatalogLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <CatalogTabs />
      {children}
    </div>
  );
}

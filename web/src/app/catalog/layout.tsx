import { CatalogTabs } from '@/components/CatalogTabs';

// カタログ配下は 1 段下がるので、ここで副ナビを出す。
// レイアウトに置くことで、一覧だけでなく詳細ページ（統制・規程・リスクの個別）にも現在地が出る。
export default function CatalogLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <CatalogTabs />
      {children}
    </div>
  );
}

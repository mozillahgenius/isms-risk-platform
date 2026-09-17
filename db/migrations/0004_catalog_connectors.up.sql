-- 0004 catalog: コネクタマニフェスト（設計書 2.11 / 3.1）
CREATE TABLE catalog.connector_manifests (
  connector   text NOT NULL, version int NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('reader','elevated_reader','writer')),
  manifest    jsonb NOT NULL,
  PRIMARY KEY (connector, version)
);

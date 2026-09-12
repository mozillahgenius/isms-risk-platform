UPDATE catalog.roles_default
   SET name_ja = CASE key
                   WHEN 'ciso' THEN '経営責任者（CISO）'
                   WHEN 'secretariat' THEN '事務局（ISMS 事務局）'
                   ELSE name_ja
                 END
 WHERE key IN ('ciso', 'secretariat');

UPDATE catalog.checks
   SET title_ja = '経営責任者（CISO）が 1 人以上いる'
 WHERE key = 'CHK-CORE-ROLE-001';

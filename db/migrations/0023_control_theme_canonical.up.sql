-- 0023 統制の分類（theme）の正規形を DB で強制する。
--
-- なぜ要るか:
--   theme は「運営基盤 / 機関設計 / 取締役会」のように ' / ' で段に割る文字列で、
--   画面は割った結果で階層を作る。ところが「その統制の分類は何か」の定義が
--   3 か所に分かれていた。
--
--     1. 画面の splitTheme … ' / ' で割り、各段を trim し、空段を捨てる
--     2. 一覧の絞り込み    … 素の `theme = ?` と `theme LIKE ? || ' / %'`
--     3. 同じ分類の件数    … 素の `theme = (…)`
--
--   同じ値のはずのものが 3 通りに解釈されるので、` A / B ` のように前後へ空白の
--   入った行が 1 件でも在ると「詳細は 2 件と言うのに、遷移先の一覧は 0 件」になる。
--   どこか 1 か所だけを正規化しても、別の 1 か所とずれるだけで終わる。
--
--   そこで**正規形でない値をそもそも保存できなくする**。以後、素の等値比較が
--   正規形の比較と一致するので、画面側で正規化する必要がなくなる。
--
-- 正規形の定義:
--   NULL（＝分類なし）か、または
--   「' / ' で割った各段が前後に空白を持たず、空の段が無く、全体が空でない」文字列。
--   空白の集合は ECMAScript の WhiteSpace ＋ LineTerminator に合わせる。
--   画面は JavaScript の trim で「分類なし」を判定するので、ここがずれると
--   「画面は分類なし・DB は分類あり」に割れる。
--
-- 実測（適用前）: catalog.controls 304 件のうち、NULL 0 件・空文字 0 件・非正規形 0 件。
--   既存データはすべて正規形なので、この制約で落ちる行は無い。

SET ROLE schema_owner;

-- 空白の集合を 1 か所で定義する。U& のエスケープは既定で \ を使う。
--   0009 TAB / 000A LF / 000B VT / 000C FF / 000D CR / 0020 SP / 00A0 NBSP / 1680 OGHAM
--   2000-200A 各種スペース / 2028 LS / 2029 PS / 202F NNBSP / 205F MMSP / 3000 全角 / FEFF BOM
CREATE FUNCTION catalog.theme_space_chars() RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005'
      || U&'\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF'
$$;

COMMENT ON FUNCTION catalog.theme_space_chars() IS
  '分類の段を trim するときに空白と見なす文字。画面側（JS の String.prototype.trim）と同じ集合。';

CREATE FUNCTION catalog.canonical_theme(p_theme text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN p_theme IS NULL THEN NULL ELSE
    array_to_string(
      array_remove(
        ARRAY(
          SELECT btrim(s, catalog.theme_space_chars())
            FROM unnest(string_to_array(p_theme, ' / ')) WITH ORDINALITY AS u(s, ord)
           ORDER BY u.ord
        ),
        ''),
      ' / ')
  END
$$;

COMMENT ON FUNCTION catalog.canonical_theme(text) IS
  '分類の正規形。画面の splitTheme(theme).join('' / '') と同じ結果になる。';

-- 空文字は許さない。分類が無いことは NULL で表す。
-- 「空文字」と「NULL」の 2 通りで同じことを表せると、比較も表示も分岐が増える。
ALTER TABLE catalog.controls
  ADD CONSTRAINT controls_theme_canonical
  CHECK (theme IS NULL OR (theme <> '' AND theme = catalog.canonical_theme(theme)));

RESET ROLE;

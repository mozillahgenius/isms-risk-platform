-- 0023 Enforce the canonical form of control classification (theme) in the DB.
--
-- Why:
--   theme is a string split into levels by ' / ', like "major / middle / minor",
--   and the screen builds the hierarchy from the split. But the definition of
--   "what is this control's classification" was split across 3 places:
--
--     1. the screen's splitTheme … splits on ' / ', trims each level, drops empty levels
--     2. list filtering          … plain `theme = ?` and `theme LIKE ? || ' / %'`
--     3. same-classification count … plain `theme = (…)`
--
--   What should be one value is interpreted 3 ways, so even one row with leading/trailing
--   spaces like ` A / B ` yields "the detail says 2 items, but the linked list shows 0".
--   Normalizing in just one place only makes it drift from another.
--
--   So **non-canonical values cannot be stored in the first place**. From then on plain equality
--   matches canonical comparison, and the screen no longer needs to normalize.
--
-- Definition of the canonical form:
--   NULL (= no classification), or
--   a string where "every level split on ' / ' has no leading/trailing whitespace, no level is
--   empty, and the whole is non-empty".
--   The whitespace set matches ECMAScript WhiteSpace + LineTerminator.
--   The screen uses JavaScript trim to decide "no classification", so a mismatch here would
--   split into "screen says none, DB says some".
--
-- Measured (before applying, on the catalog loaded at the time): 0 NULL, 0 empty, 0 non-canonical.
--   All existing data is canonical, so no row fails this constraint.

SET ROLE schema_owner;

-- Define the whitespace set in one place. U& escapes use \ by default.
--   0009 TAB / 000A LF / 000B VT / 000C FF / 000D CR / 0020 SP / 00A0 NBSP / 1680 OGHAM
--   2000-200A various spaces / 2028 LS / 2029 PS / 202F NNBSP / 205F MMSP / 3000 ideographic / FEFF BOM
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

-- Empty strings are not allowed. No classification is represented by NULL.
-- If both "empty string" and "NULL" can mean the same thing, comparison and display need more branches.
ALTER TABLE catalog.controls
  ADD CONSTRAINT controls_theme_canonical
  CHECK (theme IS NULL OR (theme <> '' AND theme = catalog.canonical_theme(theme)));

RESET ROLE;

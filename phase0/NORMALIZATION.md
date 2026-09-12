# Normalization rules for the `カルテ_リスクマップ` (risk map chart) sheet — `norm/v1`

Phase 0 acceptance means: "load an existing xlsx -> DB -> re-export an xlsx whose
content matches the input (machine diff with 0 differences)".
**A binary comparison of xlsx files cannot decide this** (creation timestamps, XML
ordering, styles and the shared-string table always differ).
So the definition of "match" is fixed as a set of rules, and **the rules themselves
are under test**.

The implementation is `phase0/karte.py`. Bump the version (`NORM_VERSION`) whenever
the rules change.

Sheet names below are the literal (Japanese) sheet names used by the workbook
template.

---

## 1. In scope and out of scope

| Sheet | Treatment |
|---|---|
| `カルテ_リスクマップ` (risk map chart) | **Compared.** Anything other than 0 differences fails |
| `リスクマップ_AUTO` (auto risk map) | Not compared (a derived sheet regenerated deterministically from the input). Covered separately by a golden test |
| `ヒートマップ_AUTO` (auto heat map) | Same as above |
| `リスクマップマスタ` (risk map master) | Not compared (not tenant data; it goes into `catalog.risk_scenario_templates`). Row count and representative records are checked by a separate test |

**Marking a sheet "out of scope" alone would let acceptance pass even if AUTO
generation broke.** Therefore the expected values are pinned in
`phase0/golden/auto_sheets.json`, and regeneration is checked against them
(`run_acceptance.sh` step 8).

---

## 2. Column mapping

The input header comes in two variants: the real template and the existing
`build_risk_map.py` disagree on names.
**The canonical names are the builder's** (because `build_risk_map.py` is called
unmodified).

| Real template | Builder (canonical) | DB destination |
|---|---|---|
| `RiskItem` | `RiskItem` | `app.risk_scenarios.area` and `phase` (functional area and phase, e.g. `経理・税務` (accounting/tax) / `1`) |
| `BigCategory` | `Big` | `app.risk_scenarios.theme` (issue theme) |
| `MidCategory` | `Mid` | `app.risk_scenarios.measure` (measure) |
| `SmallFrame` | `Frame` | `app.risk_scenarios.frame` |
| `Summary` | `Summary` | `app.risk_scenarios.summary` |
| `ProbBefore` | `ProbBefore` | `app.risk_assessments.prob` |
| `ImpactBefore` | `ImpactBefore` | `app.risk_assessments.impact_biz` |
| `ActionPlan` | `Action` | `app.risk_treatments.action_plan` |
| `ProbAfter` | `ProbAfter` | `app.risk_treatments.prob_after` |
| `ImpactAfter` | `ImpactAfter` | `app.risk_treatments.impact_biz_after` |

**Business key** = `(RiskItem, Big, Mid, Frame, Summary)`
= `(domain, theme, measure, frame, summary)` in the DB.

This mapping is a **semantic mapping**, not a column rename, so
`run_acceptance.sh` step 3 SELECTs directly from the DB and compares against the
expected values.

### Header validation (never silently ignored)

All of the following are errors:

- an unknown column
- a missing required column
- two columns mapping to the same canonical name (e.g. `Big` and `BigCategory` together)
- a duplicated column name

Only completely empty trailing columns are ignored.

---

## 3. Value normalization

### Strings (`RiskItem` / `Big` / `Mid` / `Frame` / `Summary` / `Action`)

1. **Unicode NFC**. **NFKC is not used** — NFKC folds full-width parentheses `（）`
   and full-width alphanumerics to half-width, rewriting the register values
   themselves (for example `サンプル部門A（Phase1）` -> `サンプル部門A(Phase1)`).
   The round trip would still be consistent, but changing the value stored in the
   DB relative to the original is alteration, not normalization.
2. NBSP (U+00A0) and ideographic space (U+3000) become an ASCII space
3. Line endings are unified to LF (CRLF / CR -> LF)
4. Leading/trailing whitespace is trimmed on each line, and runs of whitespace
   within a line collapse to one space
5. Leading/trailing whitespace of the whole value is trimmed
6. **Case is not changed** (mis-conversion does more harm in a mostly-Japanese register)
7. `NULL` and the empty string are treated as the same "empty". An empty value in
   any of the five business-key fields is an error
8. A string field stored in a numeric cell is stringified if it is an integer
   (a non-integer is an error)

### Numbers (`ProbBefore` / `ImpactBefore` / `ProbAfter` / `ImpactAfter`)

- A numeric cell and a string cell with the same value are treated alike (strings
  are passed through NFKC before parsing)
- **Non-integers are an error, not truncated** (`1.5` is an error)
- Values outside 1–5 are an error
- Empty is an error (required)

### Things that are errors whenever they appear

- booleans, dates, Decimal (these never appear in this sheet)
- formula cells. `data_only=True` only reads the cached value and cannot detect a
  stale cache (it would silently pass an old value), so formulas are rejected outright
- Excel error values (`#REF!` `#VALUE!` `#DIV/0!` `#NAME?` `#N/A` `#NULL!` `#NUM!`)

### Rows

- a row whose columns are all empty does not count as a row (including trailing empty rows)
- for merged cells, only the top-left cell holding the value is used
- **hidden rows are not excluded** (excluding them would be a silent loss)
- a duplicated business key is an error (duplicate rows are wrong in a register;
  the comparison is not a multiset comparison)

---

## 4. Ordering and serialization

- Row order is defined as meaningless; rows are **sorted by business key before
  comparison**
- Python sorts by **code point**; the DB side specifies `COLLATE "C"` explicitly
  (so locale differences cannot change the result)
- Serialization is **JSON Lines**: one record per line, keys in canonical column
  order, `ensure_ascii=False` / `sort_keys=True` / separators `,` and `:` (no extra
  whitespace)
- The digest is the **SHA-256 of the serialized UTF-8 bytes** (lowercase hex)

---

## 5. Differences documented as specification

The design's acceptance criteria require that "places where differences appear are
documented as specification". There are three:

1. **Header names**: even if the input uses the real-template form (`BigCategory`
   etc.), the output uses the builder's canonical names (`Big` etc.). An alias
   table absorbs this, and the values match.
2. **Sheet set**: the input's `リスクマップマスタ` (risk map master) sheet is not in
   the output (it goes into `catalog`, not tenant data). Row count and representative
   records are checked by a separate test.
3. **The two AUTO sheets**: not compared with the input's content (they are derived
   and regenerated deterministically from the input). Instead they are checked
   against the golden file.

---

## 6. Reverse checks

The rules are shown to work **by breaking things and watching them fail**
(`run_acceptance.sh` steps 6 and 7):

- rewriting one cell of the output makes the diff fail
- an input with both `Big` and `BigCategory` fails with "column collision"
- `1.5` is not truncated and fails as "non-integer"

---

## 7. Input fixture

`phase0/make_fixture.py` generates the fixture directly with openpyxl, **without
using `build_risk_map.py`**. If the generator and the verifier shared code, the round
trip would only prove self-consistency, not interoperability.

The fixture contains no real customer data (everything is what `make_fixture.py`
writes). It deliberately includes leading/trailing spaces, ideographic spaces,
newlines and all three perspectives.

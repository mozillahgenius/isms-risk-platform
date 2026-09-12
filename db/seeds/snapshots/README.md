# Sample catalog CSVs

These two files are a **small, fictional sample catalog**. They exist so that
`make seed`, `make ci` and `tests/run_isolated.sh` work out of the box. Every row
was written for this repository and is marked as a sample (`サンプル`); none of it
is a real control framework or risk library.

- `control_check/control_requirements_master.csv` (8 rows) -> `catalog.controls`
  (`framework_key = 'IPO-KARTE'`)
  - columns: `大項目記号,大項目,中項目,小項目コード,小項目,要請No,要請事項`
- `risk_map/risk_map_master.csv` (9 rows) -> `catalog.risk_scenario_templates`
  - columns: `RiskItem,Big,Mid,Frame,Summary,Action`

To use your own catalog, put CSVs with the same columns under the same relative
paths in another directory and point `LEGAL_SCRIPTS_DIR` at it:

```bash
LEGAL_SCRIPTS_DIR=/path/to/my-catalog make seed
```

`db/seeds/load_csv.py` validates the files before loading (UTF-8, required
columns, no empty values, unique codes / business keys, `RiskItem` ending in
`（PhaseN）` with N = 1..5, `Frame` one of `管理可能性` / `精度` / `スピード`).

`SHA256SUMS` pins the bundled files; `tests/run_isolated.sh` and
`scripts/ci/run.sh` verify it before loading. When you change the sample files,
regenerate it:

```bash
cd db/seeds/snapshots && shasum -a 256 control_check/control_requirements_master.csv risk_map/risk_map_master.csv > SHA256SUMS
```

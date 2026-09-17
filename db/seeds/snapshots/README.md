# Isolated-test CSV snapshots

These files are immutable fixtures for `tests/run_isolated.sh`; they are not the
production seed source of truth. Production `make seed` and
`record_provenance.py` read the configured catalog directory.

- Source: fictional sample data for tests and local development
- `control_check/control_requirements_master.csv`: SHA-256 `56e0b4a0419f49d172edab1ebacf054cf4477a796e6c03d98cffc54d2ef92ef3`
- `risk_map/risk_map_master.csv`: SHA-256 `140b484a48eb619f194eda7fa8a804ec4a5814b7f20aa042a8c9c2c38805b544`

When the upstream inputs change, update both fixtures, this manifest, and the
isolated-test expectations in one reviewed commit.

`tests/run_isolated.sh` verifies `SHA256SUMS` before loading either fixture.

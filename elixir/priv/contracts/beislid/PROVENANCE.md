# Vendored Beislið producer contracts

These files define the producer contract accepted by Rondo's in-process approved-export validator.

- Canonical repository: `https://github.com/sandsower/beislid`
- Canonical remote and ref: `origin/main`
- Canonical commit: `0c8fda12e45de6525f7e43d78e3a815380d8570f`
- Vendored source: `schemas/approved-slice-plan-export-v0.schema.json`
- Vendored source: `schemas/execution-envelope-v0.schema.json`

The two JSON files are byte-for-byte copies from the pinned commit.
Rondo intentionally implements only the schema keyword subset declared by the producer: `type`, `required`, `properties`, `enum`, `items`, `minimum`, and `pattern`.
Unknown instance properties remain additive and are not rejected.

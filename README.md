# lex-pack-coldchain

Cold-chain domain pack — temperature-envelope declarations, reefer readings, and evidence-gated excursion pricing attributed to whoever held custody.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #237](https://github.com/alpibrusl/lex-ev-fleet/issues/237)). Builds on [`lex-pack-custody`](https://github.com/alpibrusl/lex-pack-custody) at the **data** level only: it queries the shared `events` table for `kind='custody.handoff'` rows that pack's routes write, keyed by `trailer_ref`. It does not import `lex-pack-custody`'s code and does not depend on it in `lex.toml` — a deployment mounting both needs custody as its own dependency.

## Routes

```
POST /coldchain/profiles                     — declare envelope {trailer_ref, min_c, max_c, ref}
POST /coldchain/readings                     — ingest {trailer_ref, temp_c[, ts_ms, source]}
POST /coldchain/trailers/:ref/sync           — pull readings from a telemetry backend
GET  /coldchain/trailers/:ref/report         — envelope + trace + excursions-by-holder + verified chain
POST /coldchain/agreements                   — {trailer_ref, shipper, carrier, base_fee_eur, penalty_per_excursion_eur, ref}
GET  /coldchain/shipments/:ref/invoice       — terms + live excursion count + projected fee (no settlement)
POST /coldchain/shipments/:ref/settle        — settle iff the chain verifies: base - penalty×excursions, shipper -> carrier
```

## Usage

```lex
import "lex-pack-coldchain/coldchain" as coldchain

# in your router-wiring code:
let r := coldchain.mount(router.new(), db, telemetry_url)
```

`coldchain.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.

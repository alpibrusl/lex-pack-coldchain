# info.lex — the coldchain agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the coldchain-ops persona — label, tagline, starter
# prompts. Served by the host under /platform/packs's agent_packs field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "coldchain", title: "Coldchain", tagline: "Temperature-envelope custody, with excursions attributed to whoever held the trailer and settled against agreed fee terms.", personas: [{ kind: "coldchain-ops", title: "Coldchain ops", tagline: "Declares envelopes, ingests readings, reports excursions, and settles custody fees.", suggested_prompts: ["Declare an envelope for trailer TRL-COLD-01: -18C to -15C.", "Sync live telemetry for trailer TRL-COLD-01.", "Get the custody report for trailer TRL-COLD-01.", "Get the invoice for shipment SHIP-100, then settle it."] }] }
}


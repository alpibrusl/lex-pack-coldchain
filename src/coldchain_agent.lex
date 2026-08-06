# coldchain_agent.lex — an LLM-driven agent persona that operates THIS
# pack's own REST service (coldchain.lex's /coldchain/* routes).
#
# Same loopback-HTTP pattern as lex-pack-construction/src/construction_agent.lex.
# The pack's own routes already wrap the external telemetry backend (the
# /trailers/:ref/sync route takes a telemetry_url internally) -- the agent's
# tools only ever call this pack's own self_base_url, never telemetry_url
# directly.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn coldchain_capability() -> cap.Capability {
  cap.inbound("handle", "Operate temperature-envelope custody for cold-chain trailers: declare envelopes, ingest readings, sync live telemetry, report custody + excursions, and settle custody fees.", { title: "ColdchainOps", description: "Inbound message for the coldchain ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes) ────────────────────────────────
fn make_coldchain_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("declare_envelope", "Set a trailer's allowed temperature envelope (min/max Celsius). A reading outside this range is an excursion.", { title: "DeclareEnvelope", description: "Temperature envelope declaration.", fields: [sch.required_str("trailer_ref", []), sch.required_float("min_c", []), sch.required_float("max_c", []), sch.optional(sch.required_str("ref", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/coldchain/profiles"), jv.stringify(args), ""))
  }), t.define("record_reading", "Ingest a single reefer temperature reading for a trailer. Returns whether it was an excursion and, if so, who held custody at that instant.", { title: "RecordReading", description: "Temperature reading ingestion.", fields: [sch.required_str("trailer_ref", []), sch.required_float("temp_c", []), sch.optional(sch.required_int("ts_ms", [])), sch.optional(sch.required_str("source", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/coldchain/readings"), jv.stringify(args), ""))
  }), t.define("sync_reefer_telemetry", "Pull live readings from the tenant's telemetry backend for a trailer and run them through the excursion check, instead of ingesting readings one at a time.", { title: "SyncReeferTelemetry", description: "Telemetry sync.", fields: [sch.required_str("trailer_ref", []), sch.optional(sch.required_int("since_ms", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/coldchain/trailers/", jstr(args, "trailer_ref"), "/sync"], ""), jv.stringify(args), ""))
  }), t.define("get_custody_report", "Get a trailer's full report: envelope, temperature trace, every excursion attributed to who held custody at that instant, custody chain, and chain integrity.", { title: "GetCustodyReport", description: "Custody report lookup.", fields: [sch.required_str("trailer_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([self_base_url, "/coldchain/trailers/", jstr(args, "trailer_ref"), "/report"], ""), ""))
  }), t.define("create_fee_agreement", "Set the custody fee terms for a shipment: base fee plus a penalty per excursion.", { title: "CreateFeeAgreement", description: "Fee agreement creation.", fields: [sch.required_str("trailer_ref", []), sch.required_str("shipper", []), sch.required_str("carrier", []), sch.required_float("base_fee_eur", []), sch.required_float("penalty_per_excursion_eur", []), sch.required_str("ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/coldchain/agreements"), jv.stringify(args), ""))
  }), t.define("get_invoice", "Get a shipment's projected custody fee: base fee plus excursion penalties, and whether it has already been settled.", { title: "GetInvoice", description: "Invoice lookup.", fields: [sch.required_str("shipment_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.join([self_base_url, "/coldchain/shipments/", jstr(args, "shipment_ref"), "/invoice"], ""), ""))
  }), t.define("settle_shipment", "Settle a shipment's custody fee: pays the base fee plus any excursion penalties. Idempotent -- settling an already-settled shipment just replays the prior result.", { title: "SettleShipment", description: "Shipment settlement.", fields: [sch.required_str("shipment_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/coldchain/shipments/", jstr(args, "shipment_ref"), "/settle"], ""), jv.stringify(args), ""))
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn coldchain_system_prompt(id :: Str) -> Str {
  str.join(["You are coldchain ops agent ", id, ". You track reefer temperature custody and settle custody fees against it.", " Use declare_envelope to set a trailer's allowed range, record_reading or sync_reefer_telemetry to ingest temperatures, get_custody_report for the full excursion-by-custody-holder picture, create_fee_agreement to set terms, get_invoice to check the projected fee, and settle_shipment to pay it once the shipment closes.", " Be precise about trailer_ref and shipment_ref, and always name the specific trailer/shipment you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_coldchain_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := coldchain_capability()
  let cfg := { id: id, kind: "coldchain-ops", system_prompt: coldchain_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_coldchain_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Coldchain ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}


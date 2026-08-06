# tests/test_coldchain_agent.lex — pure-logic coverage for src/coldchain_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/coldchain_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(agent.make_coldchain_tools("http://127.0.0.1:8100"), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_seven_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_coldchain_tools("http://127.0.0.1:8100")) == 7, "coldchain has exactly 7 REST routes today, so exactly 7 tools should be defined")
}

fn test_declare_envelope_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("trailer_ref", JStr("TRL-COLD-01")), ("min_c", JFloat(-18.0)), ("max_c", JFloat(-15.0))])
  match schema_of("declare_envelope") {
    None => Err("declare_envelope tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("declare_envelope's schema must accept coldchain.lex's documented POST /coldchain/profiles body"),
      Ok(_) => pass(),
    },
  }
}

fn test_record_reading_schema_requires_temp_c() -> Result[Unit, Str] {
  let bad := JObj([("trailer_ref", JStr("TRL-COLD-01"))])
  match schema_of("record_reading") {
    None => Err("record_reading tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("record_reading's schema must require temp_c"),
    },
  }
}

fn test_get_custody_report_schema_requires_trailer_ref() -> Result[Unit, Str] {
  match schema_of("get_custody_report") {
    None => Err("get_custody_report tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("get_custody_report's schema must require trailer_ref"),
    },
  }
}

fn test_create_fee_agreement_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("trailer_ref", JStr("TRL-COLD-01")), ("shipper", JStr("shipper-1")), ("carrier", JStr("carrier-1")), ("base_fee_eur", JFloat(200.0)), ("penalty_per_excursion_eur", JFloat(50.0)), ("ref", JStr("AGR-1"))])
  match schema_of("create_fee_agreement") {
    None => Err("create_fee_agreement tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("create_fee_agreement's schema must accept coldchain.lex's documented POST /coldchain/agreements body"),
      Ok(_) => pass(),
    },
  }
}

fn test_settle_shipment_schema_requires_shipment_ref() -> Result[Unit, Str] {
  match schema_of("settle_shipment") {
    None => Err("settle_shipment tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("settle_shipment's schema must require shipment_ref"),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_seven_tools_defined(), test_declare_envelope_schema_accepts_documented_shape(), test_record_reading_schema_requires_temp_c(), test_get_custody_report_schema_requires_trailer_ref(), test_create_fee_agreement_schema_accepts_documented_shape(), test_settle_shipment_schema_requires_shipment_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}


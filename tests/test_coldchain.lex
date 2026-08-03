# tests/test_coldchain.lex — pure-logic coverage for src/coldchain.lex.
#
# net_fee_dec is the one pure, non-trivial money decision here (base minus
# penalty-per-excursion, floored at zero); the effectful routes (ingest,
# settle, DB) need a live DB to exercise meaningfully — that's covered by
# lex-ev-fleet's own integration testing of the mounted deployment.

import "std.list" as list

import "lex-soft/src/positions" as pos

import "../src/coldchain" as coldchain

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

# ---- net_fee_dec ------------------------------------------------------------
fn test_net_fee_dec_no_excursions_charges_full_base() -> Result[Unit, Str] {
  assert_true(coldchain.net_fee_dec("10.00", "2.00", 0) == "10.00", "zero excursions must charge the full base fee")
}

fn test_net_fee_dec_deducts_penalty_per_excursion() -> Result[Unit, Str] {
  assert_true(coldchain.net_fee_dec("10.00", "2.00", 3) == "4.00", "the net fee must be base minus penalty times excursion count")
}

fn test_net_fee_dec_floors_at_zero() -> Result[Unit, Str] {
  assert_true(coldchain.net_fee_dec("5.00", "2.00", 5) == "0.00", "a penalty exceeding the base fee must floor at zero, never go negative")
}

fn test_net_fee_dec_unparseable_terms_default_to_zero_fee() -> Result[Unit, Str] {
  assert_true(coldchain.net_fee_dec("not-a-number", "2.00", 0) == "0.00", "an unparseable base fee must fall back to a zero fee rather than guessing")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := coldchain.manifest()
  assert_true(list.is_empty(pos.validate(m)), "coldchain's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(coldchain.manifest().route_prefix == "/coldchain", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_settles() -> Result[Unit, Str] {
  assert_true(coldchain.manifest().settles, "coldchain settles a custody fee, so its manifest must declare settles: true")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_net_fee_dec_no_excursions_charges_full_base(), test_net_fee_dec_deducts_penalty_per_excursion(), test_net_fee_dec_floors_at_zero(), test_net_fee_dec_unparseable_terms_default_to_zero_fee(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_settles()]
}


# coldchain.lex — temperature-evidence custody (cold-chain pack, #123).
#
# The custody pack answers "who held the trailer, provably". This module
# answers the cold-chain question on top of it: "was the load kept inside its
# temperature envelope — and if not, WHO held the trailer when it wasn't".
#
# A shipment declares its envelope (a PROFILE), reefer readings stream in, and
# every reading outside the envelope becomes a first-class `coldchain.excursion`
# trail event ATTRIBUTED to the custody holder at that instant (the newest
# custody.handoff at or before the reading — the same per-trailer chain the
# journey endpoint re-verifies). The insurer-facing report re-derives chain
# integrity on every read; nothing in it is taken on faith.
#
#   POST /coldchain/profiles                     — declare envelope {trailer_ref, min_c, max_c, ref}
#   POST /coldchain/readings                     — ingest {trailer_ref, temp_c[, ts_ms, source]}
#   GET  /coldchain/trailers/:ref/report         — envelope + trace + excursions-by-holder + verified chain
#
# PRICING (#123). Cold-chain custody carries a premium fee — a shipper pays more
# to have a load kept inside its envelope, provably, than to ship general
# freight. So the fee is EVIDENCE-GATED, the same pay-against-proven-outcome
# thesis the flex and construction packs use: a shipment declares a base custody
# fee and a per-excursion penalty, and settlement re-derives the excursion count
# from the very readings the report already tracks, deducts penalty × excursions
# (floored at zero), and settles the remainder shipper -> carrier as an L1
# chargeback on the settlement trail. The chain must re-verify before a euro
# moves — a broken chain settles nothing. Exact decimals throughout (lex-money);
# settlement is idempotent (a second POST returns the first result, moves no
# money).
#
#   POST /coldchain/agreements                   — {trailer_ref, shipper, carrier, base_fee_eur, penalty_per_excursion_eur, ref}
#   GET  /coldchain/shipments/:ref/invoice       — terms + live excursion count + projected fee (no settlement)
#   POST /coldchain/shipments/:ref/settle        — settle iff the chain verifies: base - penalty×excursions, shipper -> carrier
#
# Domain pack over the lex-soft core: lex-trail for the chain, settlement.verify
# for integrity, settlement.record_chargeback_dec for the money, custody's own
# events for attribution. Zero core changes.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.float" as float

import "std.time" as time

import "std.sql" as sql

import "std.http" as http

import "std.bytes" as bytes

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/evidence" as evidence

import "lex-money/src/decimal" as mdec

import "lex-money/src/money" as money

import "lex-soft/src/positions" as pos

# The amount as the caller WROTE it (string passes through so no float rounding
# creeps in; a number is rendered once). Same idiom as the construction pack.
fn jdec(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => str.trim(s),
    Some(JFloat(v)) => float.to_str(v),
    Some(JInt(n)) => int.to_str(n),
    _ => "",
  }
}

# The evidence-gated custody fee, as one pure decision over exact money so it is
# testable without a DB: base fee minus (penalty per excursion × excursion
# count), floored at zero — a carrier never owes the shipper for keeping a load
# too well. Returns the payable amount formatted as a decimal string. Unparseable
# terms fall back to a zero fee rather than guessing.
fn net_fee_dec(base_dec :: Str, penalty_dec :: Str, excursions :: Int) -> Str {
  let base_m := match money.parse(base_dec, Eur, HalfUp(())) {
    Some(m) => m,
    None => money.zero(Eur),
  }
  let penalty_m := match money.parse(penalty_dec, Eur, HalfUp(())) {
    Some(m) => m,
    None => money.zero(Eur),
  }
  let total_penalty := money.scale(penalty_m, mdec.from_int(excursions), HalfUp(()))
  let net := match money.sub(base_m, total_penalty) {
    Ok(n) => n,
    Err(_) => base_m,
  }
  if money.is_negative(net) {
    money.format(money.zero(Eur))
  } else {
    money.format(net)
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jnum(j :: jv.Json, key :: Str, dflt :: Float) -> Float {
  match jv.get_field(j, key) {
    Some(JFloat(v)) => v,
    Some(JInt(n)) => int.to_float(n),
    Some(JStr(s)) => match jv.parse(s) {
      Ok(JFloat(v)) => v,
      Ok(JInt(n)) => int.to_float(n),
      _ => dflt,
    },
    _ => dflt,
  }
}

fn jint(j :: jv.Json, key :: Str, dflt :: Int) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    Some(JFloat(v)) => float.to_int(v),
    _ => dflt,
  }
}

fn row_str(row :: sql.Row, k :: Str) -> Str {
  match sql.get_str(row, k) {
    Some(v) => v,
    None => "",
  }
}

fn row_float(row :: sql.Row, k :: Str) -> Float {
  match sql.get_float(row, k) {
    Some(v) => v,
    None => 0.0,
  }
}

fn row_int(row :: sql.Row, k :: Str) -> Int {
  match sql.get_int(row, k) {
    Some(v) => v,
    None => 0,
  }
}

# Portable DDL (SQLite + Postgres): TEXT / DOUBLE PRECISION / BIGINT only.
# NOT `REAL`: lex's Postgres driver binds PFloat params as Rust f64 (float8),
# which tokio-postgres refuses to serialize against a `REAL` (float4) column
# ("error serializing parameter N") — every INSERT/UPDATE touching that column
# fails client-side before it ever reaches Postgres. Same class of gotcha as
# `INTEGER` vs `BIGINT` for Int params; see reference_lex_postgres memory.
# The ALTER TABLE ... ALTER COLUMN TYPE lines below widen already-deployed
# tables in place: a no-op on SQLite (unsupported syntax, error discarded like
# every other migration in this function) and a no-op on Postgres once
# already widened.
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __p := sql.exec(db, "CREATE TABLE IF NOT EXISTS coldchain_profiles (trailer_ref TEXT PRIMARY KEY, min_c DOUBLE PRECISION NOT NULL, max_c DOUBLE PRECISION NOT NULL, ref TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL)", [])
  let __r := sql.exec(db, "CREATE TABLE IF NOT EXISTS coldchain_readings (trailer_ref TEXT NOT NULL, ts_ms BIGINT NOT NULL, temp_c DOUBLE PRECISION NOT NULL, source TEXT NOT NULL DEFAULT '', excursion BIGINT NOT NULL DEFAULT 0, PRIMARY KEY (trailer_ref, ts_ms))", [])
  let __a := sql.exec(db, "CREATE TABLE IF NOT EXISTS coldchain_agreements (trailer_ref TEXT PRIMARY KEY, shipper TEXT NOT NULL, carrier TEXT NOT NULL, base_fee_dec TEXT NOT NULL DEFAULT '', penalty_per_excursion_dec TEXT NOT NULL DEFAULT '', ref TEXT NOT NULL DEFAULT '', settled BIGINT NOT NULL DEFAULT 0, settled_fee_dec TEXT NOT NULL DEFAULT '', excursions_charged BIGINT NOT NULL DEFAULT 0, chargeback TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL)", [])
  let __i := sql.exec(db, "CREATE INDEX IF NOT EXISTS idx_coldchain_readings_ref ON coldchain_readings(trailer_ref, ts_ms)", [])
  let __mc := sql.exec(db, "ALTER TABLE coldchain_profiles ALTER COLUMN min_c TYPE DOUBLE PRECISION", [])
  let __xc := sql.exec(db, "ALTER TABLE coldchain_profiles ALTER COLUMN max_c TYPE DOUBLE PRECISION", [])
  let __tc := sql.exec(db, "ALTER TABLE coldchain_readings ALTER COLUMN temp_c TYPE DOUBLE PRECISION", [])
  ()
}

type Profile = { min_c :: Float, max_c :: Float, ref :: Str }

fn profile_for(db :: Db, trailer_ref :: Str) -> [sql] Option[Profile] {
  match sql.query(db, "SELECT min_c, max_c, ref FROM coldchain_profiles WHERE trailer_ref = ?", [PStr(trailer_ref)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ min_c: row_float(row, "min_c"), max_c: row_float(row, "max_c"), ref: row_str(row, "ref") }),
    },
  }
}

type Agreement = { shipper :: Str, carrier :: Str, base_fee_dec :: Str, penalty_dec :: Str, ref :: Str, settled :: Bool, settled_fee_dec :: Str, excursions_charged :: Int, chargeback :: Str }

fn agreement_for(db :: Db, trailer_ref :: Str) -> [sql] Option[Agreement] {
  match sql.query(db, "SELECT shipper, carrier, base_fee_dec, penalty_per_excursion_dec, ref, settled, settled_fee_dec, excursions_charged, chargeback FROM coldchain_agreements WHERE trailer_ref = ?", [PStr(trailer_ref)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ shipper: row_str(row, "shipper"), carrier: row_str(row, "carrier"), base_fee_dec: row_str(row, "base_fee_dec"), penalty_dec: row_str(row, "penalty_per_excursion_dec"), ref: row_str(row, "ref"), settled: row_int(row, "settled") == 1, settled_fee_dec: row_str(row, "settled_fee_dec"), excursions_charged: row_int(row, "excursions_charged"), chargeback: row_str(row, "chargeback") }),
    },
  }
}

# The excursion count settlement charges against — the same excursion flag the
# report surfaces, counted straight from the readings table.
fn excursion_count(db :: Db, trailer_ref :: Str) -> [sql] Int {
  match sql.query(db, "SELECT excursion FROM coldchain_readings WHERE trailer_ref = ? AND excursion = 1", [PStr(trailer_ref)]) {
    Err(_) => 0,
    Ok(rows) => list.len(rows),
  }
}

# Is the trailer's custody chain intact? A cold-chain fee is evidence-gated:
# refuse to settle against a broken chain, since the whole premium is a claim
# about provably-held custody.
fn chain_intact(db :: Db, trailer_ref :: Str) -> [sql] Bool {
  let log := settlement.trail_on(db)
  let pat := str.concat("%\"trailer_ref\":", str.concat(jv.stringify(JStr(trailer_ref)), "%"))
  match sql.query(db, "SELECT id FROM events WHERE kind='custody.handoff' AND payload_json LIKE ? ORDER BY ts_ms DESC LIMIT 1", [PStr(pat)]) {
    Err(_) => true,
    Ok(rows) => match list.head(rows) {
      None => true,
      Some(row) => settlement.verify(log, row_str(row, "id")),
    },
  }
}

# The custody holder of a trailer at instant ts: to_agent of the newest
# custody.handoff at or before ts. Before the first handoff the load is still
# with its originator ("origin"). Same payload-LIKE tenant-slice precedent as
# custody.chain_tip / audit.agent_where.
fn holder_at(db :: Db, trailer_ref :: Str, ts_ms :: Int) -> [sql] Str {
  let pat := str.concat("%\"trailer_ref\":", str.concat(jv.stringify(JStr(trailer_ref)), "%"))
  match sql.query(db, "SELECT payload_json FROM events WHERE kind='custody.handoff' AND payload_json LIKE ? AND ts_ms <= ? ORDER BY ts_ms DESC LIMIT 1", [PStr(pat), PInt(ts_ms)]) {
    Err(_) => "origin",
    Ok(rows) => match list.head(rows) {
      None => "origin",
      Some(row) => match jv.parse(row_str(row, "payload_json")) {
        Err(_) => "origin",
        Ok(p) => {
          let agent := jstr(p, "to_agent")
          if str.is_empty(agent) {
            jstr(p, "to_vin")
          } else {
            agent
          }
        },
      },
    },
  }
}

# One reading through the same gate the POST route uses: profile check,
# upsert, excursion -> trail event attributed to the custody holder.
fn ingest_reading(db :: Db, trailer_ref :: Str, p :: Profile, temp :: Float, ts :: Int, source :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Bool {
  let out := temp < p.min_c or temp > p.max_c
  let holder := holder_at(db, trailer_ref, ts)
  let stmt := "INSERT INTO coldchain_readings (trailer_ref, ts_ms, temp_c, source, excursion) VALUES (?, ?, ?, ?, ?) ON CONFLICT (trailer_ref, ts_ms) DO UPDATE SET temp_c = ?, excursion = ?"
  let exc := if out {
    1
  } else {
    0
  }
  let __i := sql.exec(db, stmt, [PStr(trailer_ref), PInt(ts), PFloat(temp), PStr(source), PInt(exc), PFloat(temp), PInt(exc)])
  if out {
    let log := settlement.trail_on(db)
    let __e := evidence.record(log, "coldchain.excursion", holder, None, [("agent", JStr(holder)), ("trailer_ref", JStr(trailer_ref)), ("temp_c", JFloat(temp)), ("min_c", JFloat(p.min_c)), ("max_c", JFloat(p.max_c)), ("ts_ms", JInt(ts)), ("holder", JStr(holder)), ("shipment_ref", JStr(p.ref)), ("source", JStr(source))])
    true
  } else {
    false
  }
}

# Pull the trailer's reefer series from the tenant's telemetry SoR
# (lex-telemetry#13) and run every new reading through the same gate.
fn sync_from_telemetry(db :: Db, telemetry_url :: Str, trailer_ref :: Str, p :: Profile, since_ms :: Int, tenant :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] (Int, Int) {
  let url := str.concat(telemetry_url, str.concat("/trailers/", str.concat(trailer_ref, str.concat("/temps?since_ms=", int.to_str(since_ms)))))
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(20000) }
  let req := http.with_header(base, "X-Tenant-Id", tenant)
  match http.send(req) {
    Err(_) => (0, 0),
    Ok(res) => {
      let body_s := match bytes.to_str(res.body) {
        Ok(v) => v,
        Err(_) => "",
      }
      match jv.parse(body_s) {
        Ok(JList(items)) => list.fold(items, (0, 0), fn (acc :: (Int, Int), it :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] (Int, Int) {
          let ts := match jv.get_field(it, "ts_ms") {
            Some(JInt(n)) => n,
            _ => 0,
          }
          let temp := jnum(it, "temp_c", -1000.0)
          if ts == 0 or temp < -273.0 {
            acc
          } else {
            let exc := ingest_reading(db, trailer_ref, p, temp, ts, str.concat("telemetry:", jstr(it, "source")))
            match acc {
              (n, e) => (n + 1, if exc {
                e + 1
              } else {
                e
              }),
            }
          }
        }),
        _ => (0, 0),
      }
    },
  }
}

# /coldchain/shipments/:ref/settle: the chargeback (settlement.record_chargeback_dec)
# already moved money before the following `UPDATE coldchain_agreements SET settled = 1
# ...` — if that write fails, the local `settled` flag didn't stick (so a retry would
# double-settle), so it must surface as an error, not a silent 201.
fn mount(r :: router.Router, db :: Db, telemetry_url :: Str) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_profiles := router.route_effectful(r, "POST", "/coldchain/profiles", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let trailer_ref := jstr(j, "trailer_ref")
        let min_c := jnum(j, "min_c", 0.0)
        let max_c := jnum(j, "max_c", 0.0)
        if str.is_empty(trailer_ref) or max_c <= min_c {
          resp.bad_request("{\"error\":\"trailer_ref and a min_c < max_c envelope are required\"}")
        } else {
          let now := time.now_ms()
          let stmt := "INSERT INTO coldchain_profiles (trailer_ref, min_c, max_c, ref, created_ms) VALUES (?, ?, ?, ?, ?) ON CONFLICT (trailer_ref) DO UPDATE SET min_c = ?, max_c = ?, ref = ?"
          let ref := jstr(j, "ref")
          match sql.exec(db, stmt, [PStr(trailer_ref), PFloat(min_c), PFloat(max_c), PStr(ref), PInt(now), PFloat(min_c), PFloat(max_c), PStr(ref)]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => {
              let log := settlement.trail_on(db)
              let payload := jv.stringify(JObj([("trailer_ref", JStr(trailer_ref)), ("min_c", JFloat(min_c)), ("max_c", JFloat(max_c)), ("ref", JStr(ref))]))
              let __e := tlog.append(log, "coldchain.profile", None, payload)
              resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("trailer_ref", JStr(trailer_ref)), ("min_c", JFloat(min_c)), ("max_c", JFloat(max_c))])))
            },
          }
        }
      },
    }
  })
  let with_readings := router.route_effectful(with_profiles, "POST", "/coldchain/readings", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let trailer_ref := jstr(j, "trailer_ref")
        if str.is_empty(trailer_ref) {
          resp.bad_request("{\"error\":\"trailer_ref is required\"}")
        } else {
          match profile_for(db, trailer_ref) {
            None => resp.json_status(409, "{\"error\":\"no temperature profile declared for this trailer\"}"),
            Some(p) => {
              let temp := jnum(j, "temp_c", -273.0)
              let ts := jint(j, "ts_ms", time.now_ms())
              let exc := ingest_reading(db, trailer_ref, p, temp, ts, jstr(j, "source"))
              if exc {
                resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("excursion", JBool(true)), ("holder", JStr(holder_at(db, trailer_ref, ts)))])))
              } else {
                resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("excursion", JBool(false))])))
              }
            },
          }
        }
      },
    }
  })
  let with_sync := router.route_effectful(with_readings, "POST", "/coldchain/trailers/:ref/sync", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    if str.is_empty(telemetry_url) {
      resp.json_status(409, "{\"error\":\"no telemetry backend configured on this node\"}")
    } else {
      match profile_for(db, ref) {
        None => resp.json_status(409, "{\"error\":\"no temperature profile declared for this trailer\"}"),
        Some(p) => {
          let j := match jv.parse(c.body) {
            Err(_) => JObj([]),
            Ok(v) => v,
          }
          let since := jint(j, "since_ms", 0)
          let tenant := jstr(j, "tenant")
          let res := sync_from_telemetry(db, telemetry_url, ref, p, since, tenant)
          match res {
            (n, e) => resp.json(jv.stringify(JObj([("ok", JBool(true)), ("synced", JInt(n)), ("excursions", JInt(e))]))),
          }
        },
      }
    }
  })
  let with_report := router.route_effectful(with_sync, "GET", "/coldchain/trailers/:ref/report", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match profile_for(db, ref) {
      None => resp.json_status(404, "{\"error\":\"no temperature profile declared for this trailer\"}"),
      Some(p) => {
        let rows := match sql.query(db, "SELECT ts_ms, temp_c, source, excursion FROM coldchain_readings WHERE trailer_ref = ? ORDER BY ts_ms ASC", [PStr(ref)]) {
          Err(_) => [],
          Ok(rs) => rs,
        }
        let trace := list.map(rows, fn (row :: sql.Row) -> jv.Json {
          JObj([("ts_ms", JInt(row_int(row, "ts_ms"))), ("temp_c", JFloat(row_float(row, "temp_c"))), ("source", JStr(row_str(row, "source"))), ("excursion", JBool(row_int(row, "excursion") == 1))])
        })
        let excursions := list.map(list.filter(rows, fn (row :: sql.Row) -> Bool {
          row_int(row, "excursion") == 1
        }), fn (row :: sql.Row) -> [sql] jv.Json {
          let ts := row_int(row, "ts_ms")
          JObj([("ts_ms", JInt(ts)), ("temp_c", JFloat(row_float(row, "temp_c"))), ("holder", JStr(holder_at(db, ref, ts)))])
        })
        let log := settlement.trail_on(db)
        let pat := str.concat("%\"trailer_ref\":", str.concat(jv.stringify(JStr(ref)), "%"))
        let tip_rows := match sql.query(db, "SELECT id FROM events WHERE kind='custody.handoff' AND payload_json LIKE ? ORDER BY ts_ms DESC LIMIT 1", [PStr(pat)]) {
          Err(_) => [],
          Ok(rs) => rs,
        }
        let intact := match list.head(tip_rows) {
          None => true,
          Some(row) => settlement.verify(log, row_str(row, "id")),
        }
        let handoffs := match sql.query(db, "SELECT id, payload_json, ts_ms FROM events WHERE kind='custody.handoff' AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(pat)]) {
          Err(_) => [],
          Ok(rs) => rs,
        }
        let holders := list.map(handoffs, fn (row :: sql.Row) -> jv.Json {
          let payload := match jv.parse(row_str(row, "payload_json")) {
            Err(_) => JObj([]),
            Ok(v) => v,
          }
          JObj([("event_id", JStr(row_str(row, "id"))), ("ts_ms", JInt(row_int(row, "ts_ms"))), ("from_agent", JStr(jstr(payload, "from_agent"))), ("to_agent", JStr(jstr(payload, "to_agent"))), ("site", JStr(jstr(payload, "site")))])
        })
        resp.json(jv.stringify(JObj([("trailer_ref", JStr(ref)), ("shipment_ref", JStr(p.ref)), ("envelope", JObj([("min_c", JFloat(p.min_c)), ("max_c", JFloat(p.max_c))])), ("readings", JInt(list.len(rows))), ("trace", JList(trace)), ("excursions", JList(excursions)), ("custody", JList(holders)), ("chain_intact", JBool(intact))])))
      },
    }
  })
  let with_agreements := router.route_effectful(with_report, "POST", "/coldchain/agreements", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let trailer_ref := jstr(j, "trailer_ref")
        let shipper := jstr(j, "shipper")
        let carrier := jstr(j, "carrier")
        if str.is_empty(trailer_ref) or str.is_empty(shipper) or str.is_empty(carrier) {
          resp.bad_request("{\"error\":\"trailer_ref, shipper and carrier are required\"}")
        } else {
          let base_dec := match money.parse(jdec(j, "base_fee_eur"), Eur, HalfUp(())) {
            Some(m) => money.format(m),
            None => money.format(money.zero(Eur)),
          }
          let penalty_dec := match money.parse(jdec(j, "penalty_per_excursion_eur"), Eur, HalfUp(())) {
            Some(m) => money.format(m),
            None => money.format(money.zero(Eur)),
          }
          let ref := jstr(j, "ref")
          let stmt := "INSERT INTO coldchain_agreements (trailer_ref, shipper, carrier, base_fee_dec, penalty_per_excursion_dec, ref, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (trailer_ref) DO UPDATE SET shipper = ?, carrier = ?, base_fee_dec = ?, penalty_per_excursion_dec = ?, ref = ?"
          match sql.exec(db, stmt, [PStr(trailer_ref), PStr(shipper), PStr(carrier), PStr(base_dec), PStr(penalty_dec), PStr(ref), PInt(time.now_ms()), PStr(shipper), PStr(carrier), PStr(base_dec), PStr(penalty_dec), PStr(ref)]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("trailer_ref", JStr(trailer_ref)), ("shipper", JStr(shipper)), ("carrier", JStr(carrier)), ("base_fee_dec", JStr(base_dec)), ("penalty_per_excursion_dec", JStr(penalty_dec))]))),
          }
        }
      },
    }
  })
  let with_invoice := router.route_effectful(with_agreements, "GET", "/coldchain/shipments/:ref/invoice", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match agreement_for(db, ref) {
      None => resp.json_status(404, "{\"error\":\"no custody-fee agreement for this shipment\"}"),
      Some(a) => {
        let n := excursion_count(db, ref)
        let projected := net_fee_dec(a.base_fee_dec, a.penalty_dec, n)
        let intact := chain_intact(db, ref)
        resp.json(jv.stringify(JObj([("trailer_ref", JStr(ref)), ("shipper", JStr(a.shipper)), ("carrier", JStr(a.carrier)), ("base_fee_dec", JStr(a.base_fee_dec)), ("penalty_per_excursion_dec", JStr(a.penalty_dec)), ("excursions", JInt(n)), ("projected_fee_dec", JStr(projected)), ("chain_intact", JBool(intact)), ("settled", JBool(a.settled)), ("settled_fee_dec", JStr(a.settled_fee_dec))])))
      },
    }
  })
  router.route_effectful(with_invoice, "POST", "/coldchain/shipments/:ref/settle", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match agreement_for(db, ref) {
      None => resp.json_status(404, "{\"error\":\"no custody-fee agreement for this shipment\"}"),
      Some(a) => {
        if a.settled {
          resp.json_status(200, jv.stringify(JObj([("ok", JBool(true)), ("already_settled", JBool(true)), ("trailer_ref", JStr(ref)), ("paid_dec", JStr(a.settled_fee_dec)), ("excursions_charged", JInt(a.excursions_charged)), ("chargeback", JStr(a.chargeback))])))
        } else {
          if not chain_intact(db, ref) {
            resp.json_status(409, "{\"error\":\"custody chain does not verify — a cold-chain fee cannot be settled against a broken chain\"}")
          } else {
            let n := excursion_count(db, ref)
            let net := net_fee_dec(a.base_fee_dec, a.penalty_dec, n)
            let log := settlement.trail_on(db)
            match settlement.record_chargeback_dec(log, a.shipper, a.carrier, net, "EUR", ref) {
              Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
              Ok(cb_id) => {
                match sql.exec(db, "UPDATE coldchain_agreements SET settled = 1, settled_fee_dec = ?, excursions_charged = ?, chargeback = ? WHERE trailer_ref = ?", [PStr(net), PInt(n), PStr(cb_id), PStr(ref)]) {
                  Err(e) => resp.json_status(500, jv.stringify(JObj([("error", JStr(str.concat("chargeback ", str.concat(cb_id, str.concat(" settled but agreement record update failed — reconcile manually: ", e.message)))))]))),
                  Ok(_) => {
                    let payload := jv.stringify(JObj([("trailer_ref", JStr(ref)), ("shipment_ref", JStr(a.ref)), ("from_agent", JStr(a.shipper)), ("to_agent", JStr(a.carrier)), ("base_fee_dec", JStr(a.base_fee_dec)), ("penalty_per_excursion_dec", JStr(a.penalty_dec)), ("excursions", JInt(n)), ("amount_dec", JStr(net)), ("chargeback", JStr(cb_id))]))
                    let __e := tlog.append(log, "coldchain.custody_fee.settled", None, payload)
                    resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("trailer_ref", JStr(ref)), ("shipper", JStr(a.shipper)), ("carrier", JStr(a.carrier)), ("base_fee_dec", JStr(a.base_fee_dec)), ("excursions_charged", JInt(n)), ("paid_dec", JStr(net)), ("chargeback", JStr(cb_id))])))
                  },
                }
              },
            }
          }
        }
      },
    }
  })
}

# The domain vocabulary this pack speaks, in the engine's position words
# (lex-soft/src/positions). An onboarding surface reads this instead of
# hardcoding a role list, so a party here can be described without the surface
# knowing anything about temperature.
fn manifest() -> pos.PackManifest {
  { id: "coldchain", title: "Cold chain", tagline: "Custody with a monitored condition envelope — excursions attributed to whoever held it.", pattern: "custody_chain", subject: "shipment", subject_ref_field: "trailer_ref", custody_ref_field: "trailer_ref", parties: [{ position: "originator", name: "shipper", title: "Shipper — owns the goods and pays for the move", field: "shipper", required: true }, { position: "executor", name: "carrier", title: "Carrier — performs the move under the envelope", field: "carrier", required: true }, { position: "custodian", name: "holder", title: "Holder — whoever has custody when a reading lands", field: "holder", required: false }, { position: "attestor", name: "source", title: "Condition source — the sensor or feed a reading came from", field: "source", required: false }, { position: "observer", name: "insurer", title: "Insurer — reads the liability report without acting in the flow", field: "", required: false }], relationships: [{ from: "shipper", to: "carrier", role: "contracted", label: "the shipper tenders the shipment under an agreed condition envelope" }, { from: "carrier", to: "holder", role: "custody", label: "the carrier hands custody on at each leg" }, { from: "source", to: "holder", role: "reporting", label: "condition readings are attributed to whoever holds the shipment" }, { from: "carrier", to: "insurer", role: "reporting", label: "the liability report is written for the insurer" }], event_kinds: ["coldchain.profile", "coldchain.excursion", "coldchain.custody_fee.settled"], evidence_kinds: ["condition_reading", "custody_handoff"], settles: true, route_prefix: "/coldchain" }
}


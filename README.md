# lex-pack-coldchain

Cold-chain domain pack — temperature-envelope declarations, reefer readings, and excursion attribution over lex-pack-custody's chain of custody.

> **Status: scaffold.** This pack is being extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) — see [https://github.com/alpibrusl/lex-ev-fleet/issues/237](https://github.com/alpibrusl/lex-ev-fleet/issues/237) for the extraction plan and what still needs to move here. Depends on lex-pack-custody — extract that one first.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine) -> this pack (one vertical's routes + `pack.DomainPack`) -> [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.

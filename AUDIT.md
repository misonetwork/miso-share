# Security Audit — `miso_share`

**Revision:** working tree @ `d67ff8c` (`main`) · **Date:** 2026-08-22 ·
**Toolchain:** sui 1.77.2 · **Framework:** pinned rev
`06734f6ff0af45d8632a14a4dc4b100197f6b1a2`

Audit of `miso_share`, the fixed-supply share issuance package that is the
economic root of the ecosystem: every share supply (10,000,000.000000 tokens,
6 decimals, permanently fixed, freeze-proof) passes through
`share::initialize`. Verdict: **safe to publish — no exploitable findings.**

## What it does

`initialize<Share>(currency, treasury_cap)` (`share.move:67`) enforces six
gates, then mints the fixed supply and consumes the cap via
`make_supply_fixed`:

| # | Gate | Error |
|---|------|-------|
| 1 | Type name ends with `::share::Share` | `EInvalidShareType` (2) |
| 2 | `MetadataCap` deleted (metadata frozen) | `EMetadataCapNotDeleted` (1) |
| 3 | Presented cap == canonical recorded cap | `ETreasuryCapMismatch` (5) |
| 4 | Currency not regulated | `ERegulatedCurrency` (4) |
| 5 | Decimals == 6 | `EInvalidDecimals` (3) |
| 6 | Outstanding supply == 0 | `ENotZeroSupply` (0) |

Threat model: a malicious share-package publisher trying to issue a token
that passes all gates but retains inflation, freeze, or metadata authority.

## Cap uniqueness — the load-bearing proof

Exactly one `TreasuryCap<Share>` can exist per share type. Every creation
path in the framework is closed except one:

- `coin::create_currency*` and `coin_registry::new_currency_with_otw` are
  OTW-gated. An OTW must be named after its module **uppercased**
  (`SHARE`); the share gate requires `share::Share` — never an OTW — so all
  legacy paths abort for share types.
- `coin_registry::new_currency<T: key>` is callable only from `T`'s defining
  module and singleton-guarded (`registry.exists<T>()` +
  `derived_object::claim`), recording the cap ID at creation.
- `coin::new_treasury_cap` is `public(package)`; the only other constructor
  is `#[test_only]`.

So: one currency per share type, one cap per currency, always the recorded
one. Downstream royalty math can rely on supply == 10¹³ forever.

## Findings

- **F1 (Low, fixed): `make_supply_fixed` accepts any cap.** It never checks
  cap identity (`coin_registry.move:299`). Unreachable today (cap
  uniqueness), but `initialize` now asserts
  `treasury_cap_id == some(id(cap))` (`share.move:87`) — the guarantee is
  enforced at issuance instead of delegated to framework mechanics.
- **F2 (Low, closed by F1): `is_regulated()` reads `RegulatedState::Unknown`
  as unregulated.** Legacy-migrated currencies carry `Unknown` (possibly
  concealing a legacy `DenyCapV2`) — but also `treasury_cap_id: none`, so F1
  rejects them first. (`set_treasury_cap_id` can fill a `none`, but only with
  a real same-type cap — which cannot exist for share types.)
- **F3 (retracted): dual-cap inflation.** An earlier hypothesis — legacy
  `create_currency` cap + registry cap for the same type — was investigated
  and disproven: the share-name/OTW mismatch kills the legacy path, and an
  OTW-shaped struct with `key` is rejected at publish. Recorded so readers
  know the attack was considered and killed by evidence.

## Edge cases (all verified)

- **Double-initialize** aborts `ETreasuryCapMismatch` (canonical cap already
  consumed; fires before the zero-supply gate).
- **Mint-then-burn laundering** passes gate 6 but is benign: supply == 0 ⟺
  zero outstanding value; post-init `total_supply()` reads exactly 10¹³. The
  gate proves "zero outstanding," which is the economically correct meaning.
- **Suffix-gate attacks** all rejected: `xshare` module (off-by-one),
  generic `Share<T>`, multi-byte/window-slide tricks (impossible — ASCII
  identifiers, fixed 64-hex address prefix). Cross-address `share::Share` is
  accepted **by design** (name convention, not allowlist).
- **No deny authority can arise post-finalize**: `new_deny_cap_v2` is
  package-private, `make_regulated` needs the consumed initializer, legacy
  paths are OTW-gated.
- **Caller model**: only the cap holder can call `initialize`; the returned
  full-supply `Balance` stays in their transaction. Usage caveat: an issuer
  who shares/wraps the cap first lets the executor pocket the supply —
  keep the cap issuer-owned until initialization.

## Verification

- **9/9 unit tests** — happy path, every abort gate, suffix matrix, and the
  migrated-currency property (`treasury_cap_id` none ∧ reads unregulated).
- **Mutation testing**: deleting/neutering the F1 assert, changing its abort
  code, or flipping the property test each fails the suite — the tests are
  non-vacuous and discriminating.
- **Probe testing**: 6 adversarial probes in sandbox packages (double-init,
  suffix bypasses, cross-address, mint-then-burn, burn-only, decimals 5/7) —
  all gates held.
- **Downstream differential**: `miso` protocol suite 50/50 identical against
  pinned vs hardened share (canary-poisoned build proved the patched source
  was really compiled).
- **Lint/bytecode hygiene**: `build --lint` clean; test-only symbols absent
  from published bytecode.

**Load-bearing framework assumptions** (verified at the pinned rev;
re-verify on framework change): the private-generics gate on `new_currency`;
OTW verifier + native semantics; the registry singleton; `option::fill`
abort-on-set.

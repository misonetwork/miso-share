# Security Audit — `miso_share`

**Package:** `miso_share` (`sources/share.move` — single module, `miso_share::share`)
**Audit date:** 2026-08-22
**Toolchain:** sui 1.77.2
**Framework reference:** Sui framework sources audited at pinned revision
`06734f6ff0af45d8632a14a4dc4b100197f6b1a2`
(cached at `~/.move/git/https___github_com_MystenLabs_sui_git_06734f6…/crates/sui-framework/packages/sui-framework/sources/`)

This document records an in-depth security audit of `miso_share`: the security
model, the findings (including one hypothesis that was investigated and
*disproven*), the edge cases exercised, and the verification methodology. Its
goal is to let a reader independently evaluate why the package can be trusted
as the economic root of the ecosystem: every share supply — 10,000,000.000000
tokens, 6 decimals, permanently fixed, freeze-proof — passes through
`share::initialize`.

## Scope

- `sources/share.move` (working tree as of the audit date, including the
  canonical-treasury-cap hardening described in Finding F1)
- `tests/` — the test suite is part of the audited surface, since it encodes
  the intended security properties
- The pinned Sui framework code that `miso_share` relies on: `coin.move`,
  `coin_registry.move`, `types.move`, `balance.move`, `option.move`
- Downstream impact: the `miso` protocol package (`misonetwork/protocol`),
  whose `composition::new` and `recording::new` route share issuance through
  `initialize`

## Security goals

`initialize<Share>(currency, treasury_cap)` (`share.move:67`) must guarantee:

1. **Fixed supply.** Exactly `SUPPLY = 10_000_000_000_000` (`share.move:27`)
   is minted, and no further minting is ever possible.
2. **Freeze-proof equity.** No deny-list or global-pause authority
   (`DenyCapV2`) can exist over a share currency — now or later.
3. **Frozen metadata.** Name, symbol, decimals, icon can never change after
   initialization.
4. **Well-formed shares.** 6 decimals; zero pre-existing outstanding supply;
   the type is a `share::Share` type by name convention.
5. **Canonical issuance.** The supply is fixed using the one treasury cap the
   registry recorded at currency creation — not any other cap of the same type.

## Threat model

The primary adversary is a **malicious share-package publisher** — someone
who controls the module defining `Share` and wants to issue a currency that
*appears* to be a well-formed fixed-supply share token (passes all gates) but
retains a way to inflate supply, freeze holders, or mutate metadata later.
Secondary adversaries: third parties attempting to initialize, re-initialize,
or interfere with someone else's share currency, and accidents in legitimate
issuance flows.

The gates in `initialize`, in evaluation order:

| # | Check | Error | Location |
|---|-------|-------|----------|
| 1 | Type name ends with `::share::Share` | `EInvalidShareType` (2) | `share.move:72`, matcher at `122–137` |
| 2 | `MetadataCap` deleted | `EMetadataCapNotDeleted` (1) | `share.move:75` |
| 3 | Presented cap == canonical recorded cap | `ETreasuryCapMismatch` (5) | `share.move:87–90` |
| 4 | Currency not regulated | `ERegulatedCurrency` (4) | `share.move:95` |
| 5 | Decimals == 6 | `EInvalidDecimals` (3) | `share.move:97` |
| 6 | Outstanding supply == 0 | `ENotZeroSupply` (0) | `share.move:99` |

Then: mint `SUPPLY` (`share.move:102`), consume the cap via
`make_supply_fixed` (`share.move:105`), emit `ShareInitializedEvent`
(`share.move:107`).

## Why exactly one treasury cap can exist per share type

This is the load-bearing fact behind the whole design, and it was verified
against the pinned framework rather than assumed.

Every `TreasuryCap<T>` creation path in the framework:

- `coin::create_currency` (`coin.move:224`) and the two deprecated regulated
  wrappers (`coin.move:262`, `coin.move:634`) — all assert
  `sui::types::is_one_time_witness(&witness)`.
- `coin_registry::new_currency_with_otw` (`coin_registry.move:209`) — same
  OTW assert at line 219.
- `coin_registry::new_currency` (`coin_registry.move:174`) — no witness, but
  singleton-guarded by `assert!(!registry.exists<T>())` (line 183) and
  `derived_object::claim(CurrencyKey<T>())`, and callable only from `T`'s
  defining module (private-generics gate; see Assumptions).
- `coin::new_treasury_cap` is `public(package)` (`coin.move:523`);
  `create_treasury_cap_for_testing` (`coin.move:585`) is `#[test_only]` and
  does not exist on-chain.

A one-time witness must be named exactly like its module, **uppercased**,
with a single `bool` field and only the `drop` ability — enforced both by the
publish-time bytecode verifier and at runtime by the `is_one_time_witness`
native. The share-type gate requires module `share`, struct `Share`
(`SHARE_TYPE` suffix, `share.move:32`). `Share` ≠ `SHARE`, so a qualifying
share type is **never** a one-time witness, and every witness-based cap
constructor aborts for it. That leaves `new_currency` as the only path —
which creates exactly one currency (registry singleton) with exactly one cap,
whose ID is recorded on the currency at creation (`coin_registry.move:196`).

Consequently: one currency per share type, one cap per currency, and the cap
is always the recorded one.

## Findings

### F1 — `make_supply_fixed` does not verify cap identity → canonical-cap assert added

**Severity:** Low (defense-in-depth; no live exploit path under the pinned
framework).
**Status:** Fixed in this working tree.

`coin_registry::make_supply_fixed(currency, cap)` (`coin_registry.move:299–306`)
swaps `SupplyState::Unknown → Fixed` and consumes **whatever** cap it is
handed, without comparing it to the `treasury_cap_id` recorded at currency
creation. If a second cap of the same type ever existed, `initialize` could be
called with it and the currency would read `Fixed` while the real cap stayed
live.

Under the pinned framework this is unreachable (the cap-uniqueness proof
above), but the guarantee was implicit and delegated to framework mechanics
three layers down. `initialize` now asserts it directly:

```move
assert!(
    currency.treasury_cap_id() == option::some(object::id(&treasury_cap)),
    ETreasuryCapMismatch,
);
```

(`share.move:87–90`). If the framework ever grows another cap-creation or
migration path, issuance now fails loudly instead of silently producing an
inflatable share token.

### F2 — `is_regulated()` reads `RegulatedState::Unknown` as unregulated (fail-open)

**Severity:** Low (unreachable for share types; closed as a side effect of F1).
**Status:** Mitigated in this working tree.

`is_regulated()` returns `true` only for `RegulatedState::Regulated`
(`coin_registry.move:622–628`). Legacy-migrated currencies are created with
`RegulatedState::Unknown` (`migrate_legacy_metadata_impl`,
`coin_registry.move:718–719`) — which may conceal a live legacy `DenyCapV2` —
yet read as unregulated. The fail-closed ideal ("require `Unregulated`
explicitly") is not directly implementable: the framework exposes no accessor
for the raw state, and `is_migrated_from_legacy` is module-private
(`coin_registry.move:646`).

However, migrated currencies are also created with `treasury_cap_id: none`,
so the F1 assert rejects them before the regulated check is evaluated. One
subtlety, verified during adversarial review: `set_treasury_cap_id`
(`coin_registry.move:433`) can later *fill* a migrated currency's `none` — it
uses `option::fill`, which aborts if a value is already set, so it cannot
touch registry-native currencies — but filling requires presenting a real
`TreasuryCap<T>` of that type, and no legacy `TreasuryCap` of a share type
can ever exist (OTW-gated constructors). For share types, the `Unknown` case
is therefore unreachable after the F1 assert. This is documented in the code
comments at `share.move:76–86` and by the test
`migrated_legacy_currency_carries_no_recorded_cap`.

### F3 — *Retracted hypothesis:* dual-cap inflation via legacy + registry paths

**Severity:** None — investigated and disproven. Recorded for transparency.

An earlier audit round hypothesized that a malicious share package could hold
two live `TreasuryCap<Share>` instances — one from the legacy
`coin::create_currency` OTW path and one from `coin_registry::new_currency` —
hand one to `initialize` and keep the other for post-fixing inflation.

The hypothesis fails on two independent grounds:

1. `miso_share`'s own suffix gate requires the type to be named `Share` in
   module `share`, which can never satisfy the one-time-witness rule (type
   name must equal the *uppercased* module name). Every witness-gated
   constructor — including all legacy `coin::create_currency*` paths —
   aborts for such a type.
2. Even the hypothetical workaround (an OTW-shaped struct with an added `key`
   ability to satisfy `new_currency<T: key>`) is rejected at publish time:
   the one-time-witness verifier requires OTW candidates to have exactly the
   `drop` ability and nothing else.

Cap uniqueness for share types is therefore a framework-enforced fact, not a
convention. This retraction is also why `ERegulatedCurrency` bypass via
legacy migration (F2) has no live path: no legacy currency of a share type
can ever be created to be migrated.

## Edge cases exercised

These were probed empirically (throwaway test packages) or established by
framework source reading. All behaved correctly.

- **Double initialization.** A second `initialize` call on an
  already-initialized currency is impossible twice over: the canonical cap was
  consumed by `make_supply_fixed`, so any second attempt presents a
  non-canonical cap and aborts with `ETreasuryCapMismatch` (this assert fires
  *before* the zero-supply check, making `ENotZeroSupply` unreachable on
  re-initialize — `ENotZeroSupply` remains reachable via pre-minting before
  the first `initialize`). Even with a hypothetical second cap,
  `make_supply_fixed` aborts on an already-fixed supply.
- **Mint-then-burn "laundering".** The zero-supply gate checks
  `treasury_cap.supply().value() == 0`, which is *current outstanding* supply:
  pre-minting and then burning everything passes the gate. Verified benign:
  every non-zero `Balance<Share>` originates from the unique `Supply`
  (`increase_supply`/`decrease_supply`, `balance.move:56–68`), so supply ==
  0 ⟺ zero outstanding value, and after initialization
  `currency.total_supply()` reads exactly `SUPPLY`. The gate proves "zero
  outstanding," not "never minted" — economically equivalent here.
- **Suffix-gate attacks.** Module `xshare` with struct `Share` (off-by-one
  window) — rejected; the suffix's leading `::` pins the module boundary.
  Generic `Share<T>` — rejected; type arguments serialize into the name, so
  the tail ends with `>`. Multi-byte tricks — impossible; identifiers are
  ASCII and the address is a fixed 64-hex-char prefix, so the 14-byte window
  cannot slide. Length underflow — guarded by checked arithmetic
  (fail-closed).
- **Cross-address same-name types.** A *different* package defining its own
  `share::Share` passes the gate and initializes successfully. This is by
  design: the gate is a naming convention, not an allowlist; each share type
  gets its own singleton currency.
- **Regulated-before-finalize.** Calling `make_regulated` on the initializer
  before finalization produces a currency that aborts with
  `ERegulatedCurrency` (test-covered). Post-finalize, no `DenyCapV2<Share>`
  can ever come into being: `coin::new_deny_cap_v2` is `public(package)`
  (`coin.move:513`), `make_regulated` needs the consumed initializer, and
  legacy paths are OTW-gated.
- **Pre-finalize supply fixing.** `make_supply_fixed_init` /
  `make_supply_burn_only_init` consume the treasury cap into the initializer
  (`coin_registry.move:284–296`), leaving the recorded cap ID dangling —
  such a currency can never be `initialize`d. Correct: its supply policy was
  already set by its issuer.
- **Decimals boundaries.** 5 and 7 both abort with `EInvalidDecimals`
  (probe-tested); the check is an exact `== 6`.
- **Arithmetic.** `mint_balance` asserts `value <= u64::MAX - self.value`
  (`balance.move:56–59`); supply is gated to 0 and `SUPPLY` = 10¹³, so no
  overflow is possible.
- **Caller model.** Only the holder of the canonical cap object can call
  `initialize` — a PTB cannot reference an object the sender does not
  control, and the returned full-supply `Balance` stays inside the caller's
  transaction. Usage caveat (not a package flaw): an issuer who shares or
  wraps the cap before initializing lets whoever executes the call pocket the
  full supply. The documented flow keeps the cap issuer-owned until
  initialization.
- **Metadata freeze.** After the metadata cap is deleted, `claim_metadata_cap`
  and `update_from_legacy_metadata` both abort permanently (`Deleted` counts
  as claimed); metadata is immutable.

## Verification methodology

Five independent techniques were applied; all artifacts were produced against
the working tree under audit.

1. **Unit tests — 9/9 passing** (`sui move test`). Happy path plus every abort
   gate, the suffix matrix (wrong module, wrong struct name), and the
   migrated-currency property test. The test-only fixtures build currencies
   through the real `coin_registry::new_currency` path, not mocks.
2. **Mutation testing** — proves the tests are not vacuous. Deleting the F1
   assert and neutering it (`assert!(true, …)`) each fail
   `initialize_rejects_non_canonical_treasury_cap`; changing the assert's
   abort code fails with "aborted with code 3, expected code 5" (the
   `expected_failure(abort_code = …)` mirrors discriminate); flipping
   `is_none()` to `is_some()` fails the migrated-currency property test;
   swapping the F1/F2 assert order leaves the suite green (ordering is
   documented, not load-bearing for the fixtures). All mutations were
   performed on backups and restored byte-identical.
3. **Probe testing** — six adversarial probes (double-initialize, two suffix
   bypass attempts, cross-address acceptance, mint-then-burn, burn-only
   pre-consumption, decimals boundaries) run in throwaway `/tmp` package
   copies. All gates held; no unexpected successes and no wrong abort codes.
4. **Downstream differential testing.** The `miso` protocol suite
   (50 tests) was run twice: against the pinned pre-change `miso_share` rev
   and against the locally hardened copy — **50/50 both times, identical
   results**, including
   `composition_new_initializes_fixed_share_supply`, which drives
   `share::initialize` through the production `composition::new` path. A
   canary run (deliberate syntax error injected into the local share copy)
   failed the downstream build citing the local path, proving the patched run
   genuinely compiled the hardened source rather than a stale cache.
5. **Lint and bytecode hygiene.** `sui move build`, `--lint`, and
   `--lint --test` are warning-clean. Inspection of the built
   `bytecode_modules/share.mv` confirms no test-only symbols are present in
   the published bytecode surface.

## Load-bearing external assumptions

The package's security rests on these framework behaviors, verified at the
pinned revision. They should be re-verified if the package is ever built
against a different framework version:

1. **Private-generics gate on `coin_registry::new_currency<T>`**
   (`coin_registry.move:174`, marked `/* internal */`): only the module
   defining `T` may call it. This is enforced by the VM/adapter verifier and
   is not visible in Move source; it is long-standing Sui behavior that the
   wider ecosystem already relies on. Without it, anyone could register a
   currency for someone else's share type.
2. **One-time-witness semantics**: the publish-time verifier (OTW candidates
   must be `drop`-only, single bool field, instantiated only in `init`) and
   the `is_one_time_witness` native (name == uppercased module name, single
   bool field).
3. **Registry singleton**: `CoinRegistry.exists<T>()` plus
   `derived_object::claim(CurrencyKey<T>())` guarantee one registry currency
   per type.
4. **`option::fill` abort semantics** (`option.move:69–72`), which make
   `set_treasury_cap_id` unable to overwrite an already-recorded cap ID.

## Informational notes (non-issues)

- `treasury_cap.supply()` (`share.move:99`) resolves to the deprecated
  `coin::supply` accessor (`coin.move:609`); `supply_immut` is the modern
  spelling. Behavior-identical, and irrelevant once bytecode is frozen at
  publish.
- A migrated currency's `treasury_cap_id: none` can later be filled by
  `set_treasury_cap_id` — by design of the framework's migration flow. It
  cannot affect share types (no legacy cap can exist to fill it with), and it
  cannot overwrite a registry-native currency's recorded ID.
- `ENotZeroSupply` is unreachable on re-initialization (see Edge cases); it
  guards first-time initialization against pre-minted supply.

## Test matrix

| Test | Property proven |
|------|-----------------|
| `initialize_mints_fixed_supply` | Happy path: exact supply, supply fixed, event emitted |
| `initialize_rejects_undeleted_metadata_cap` | Gate 2 |
| `initialize_rejects_non_canonical_treasury_cap` | Gate 3 (F1) |
| `initialize_rejects_regulated_currency` | Gate 4 |
| `initialize_rejects_wrong_decimals` | Gate 5 |
| `initialize_rejects_existing_supply` | Gate 6 (pre-mint) |
| `initialize_rejects_wrong_module_name` | Gate 1 (`::notshare::Share`) |
| `initialize_rejects_wrong_struct_name` | Gate 1 (`::share::Shares`) |
| `migrated_legacy_currency_carries_no_recorded_cap` | F2 mechanism: migrated ⇒ `treasury_cap_id` none ∧ `is_regulated()` false |

Untestable-by-construction paths, stated explicitly rather than silently
omitted: generic-`Share<T>` rejection (no generic share type can be declared
in the test module alongside the real one — probe-tested in a side package
instead); `initialize` against a migrated share-type currency (such a currency
cannot be constructed even in tests — the property test above is the
substitute); the suffix-window underflow guard (unreachable: every struct
TypeName serializes well beyond the 14-byte suffix).

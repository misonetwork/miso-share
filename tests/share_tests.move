// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for `share::initialize` — the economic root of the ecosystem: every
/// share supply (10M tokens, 6 decimals, permanently fixed) passes through it,
/// and the `::share::Share` type-suffix gate decides what counts as a share
/// type. Covers the happy path, all four abort gates, and the suffix matrix.
#[test_only]
module miso_share::share_tests;

use miso_share::legacyotw;
use miso_share::notshare;
use miso_share::share::{Self, Share, Shares, ShareInitializedEvent};
use std::unit_test::{assert_eq, destroy};

/// 10,000,000.000000 tokens at 6 decimals — must match share::SUPPLY.
const SUPPLY: u64 = 10_000_000_000_000;

// Error codes from share.move
const ENotZeroSupply: u64 = 0;
const EMetadataCapNotDeleted: u64 = 1;
const EInvalidShareType: u64 = 2;
const EInvalidDecimals: u64 = 3;
const ERegulatedCurrency: u64 = 4;
const ETreasuryCapMismatch: u64 = 5;

#[test]
fun initialize_mints_fixed_supply() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(6, ctx);
    currency.delete_metadata_cap(metadata_cap);

    let balance = share::initialize<Share>(&mut currency, treasury_cap);

    // The full fixed supply is returned, and the supply is permanently fixed
    // (the treasury cap was consumed by make_supply_fixed).
    assert_eq!(balance.value(), SUPPLY);
    assert!(currency.is_supply_fixed());
    assert_eq!(currency.total_supply(), option::some(SUPPLY));
    assert_eq!(sui::event::events_by_type<ShareInitializedEvent>().length(), 1);

    destroy(balance);
    destroy(currency);
}

// === Abort gates ===

#[test, expected_failure(abort_code = EMetadataCapNotDeleted, location = share)]
fun initialize_rejects_undeleted_metadata_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(6, ctx);

    let balance = share::initialize<Share>(&mut currency, treasury_cap);

    destroy(balance);
    destroy(currency);
    destroy(metadata_cap);
    abort
}

#[test, expected_failure(abort_code = ERegulatedCurrency, location = share)]
fun initialize_rejects_regulated_currency() {
    let ctx = &mut tx_context::dummy();
    // A share currency that is valid in every other respect (6 decimals,
    // metadata cap deleted, zero supply, correct type) but was made regulated:
    // its issuer holds a live DenyCapV2 and could freeze holders forever.
    let (mut currency, treasury_cap, metadata_cap, deny_cap) =
        share::new_regulated_share_currency_for_testing(ctx);
    currency.delete_metadata_cap(metadata_cap);

    let balance = share::initialize<Share>(&mut currency, treasury_cap);

    destroy(balance);
    destroy(currency);
    destroy(deny_cap);
    abort
}

#[test, expected_failure(abort_code = EInvalidDecimals, location = share)]
fun initialize_rejects_wrong_decimals() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(9, ctx);
    currency.delete_metadata_cap(metadata_cap);

    let balance = share::initialize<Share>(&mut currency, treasury_cap);

    destroy(balance);
    destroy(currency);
    abort
}

#[test, expected_failure(abort_code = ENotZeroSupply, location = share)]
fun initialize_rejects_existing_supply() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, mut treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(6, ctx);
    currency.delete_metadata_cap(metadata_cap);

    // Pre-mint a single unit: the supply is no longer zero.
    let coin = sui::coin::mint(&mut treasury_cap, 1, ctx);
    let balance = share::initialize<Share>(&mut currency, treasury_cap);

    destroy(coin);
    destroy(balance);
    destroy(currency);
    abort
}

#[test, expected_failure(abort_code = ETreasuryCapMismatch, location = share)]
fun initialize_rejects_non_canonical_treasury_cap() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap, metadata_cap) =
        share::new_share_currency_for_testing(6, ctx);
    currency.delete_metadata_cap(metadata_cap);

    // A second, forged cap for the same type: a valid `TreasuryCap<Share>`,
    // but not the cap the registry recorded at currency creation.
    let forged_cap = sui::coin::create_treasury_cap_for_testing<Share>(ctx);
    let balance = share::initialize<Share>(&mut currency, forged_cap);

    destroy(treasury_cap);
    destroy(balance);
    destroy(currency);
    abort
}

/// Proves the framework property the canonical-cap assert relies on to reject
/// legacy-migrated currencies: as migrated, they carry NO recorded treasury
/// cap ID. (`set_treasury_cap_id` can fill it later — but only with a real
/// `TreasuryCap<T>`, and no legacy cap of a share type can ever exist, since
/// every legacy constructor is OTW-gated and `::share::Share` is never a
/// one-time witness.) Also documents the fail-open gap being closed: such a
/// currency's regulated state is `Unknown`, which `is_regulated()` reads as
/// unregulated.
#[test]
#[allow(deprecated_usage)]
fun migrated_legacy_currency_carries_no_recorded_cap() {
    let ctx = &mut tx_context::dummy();
    let mut registry = sui::coin_registry::create_coin_data_registry_for_testing(ctx);
    let (treasury_cap, metadata) = sui::coin::create_currency(
        legacyotw::new_for_testing(),
        6,
        b"LEG",
        b"Legacy",
        b"",
        option::none(),
        ctx,
    );
    let currency = sui::coin_registry::migrate_legacy_metadata_for_testing(
        &mut registry,
        &metadata,
        ctx,
    );

    // The fail-open gap: a migrated currency reads as unregulated...
    assert!(!currency.is_regulated());
    // ...but as migrated carries no recorded treasury cap, so `initialize`'s
    // canonical-cap assert rejects it (the ID could only be filled later via
    // `set_treasury_cap_id` with a real `TreasuryCap<T>` — impossible for
    // share types, whose legacy caps can never exist).
    assert!(currency.treasury_cap_id().is_none());

    destroy(treasury_cap);
    destroy(metadata);
    destroy(currency);
    destroy(registry);
}

// === Type-suffix gate ===

#[test, expected_failure(abort_code = EInvalidShareType, location = share)]
fun initialize_rejects_wrong_module_name() {
    let ctx = &mut tx_context::dummy();
    // `::notshare::Share` — right struct name, wrong module.
    let (mut currency, treasury_cap, metadata_cap) = notshare::new_currency_for_testing(ctx);

    let balance = share::initialize<notshare::Share>(&mut currency, treasury_cap);

    destroy(balance);
    destroy(currency);
    destroy(metadata_cap);
    abort
}

#[test, expected_failure(abort_code = EInvalidShareType, location = share)]
fun initialize_rejects_wrong_struct_name() {
    let ctx = &mut tx_context::dummy();
    // `::share::Shares` — right module, struct name shifts the suffix window
    // by one byte. Catches any "ends with Share" sloppiness in the matcher.
    let (mut currency, treasury_cap, metadata_cap) = share::new_shares_currency_for_testing(ctx);

    let balance = share::initialize<Shares>(&mut currency, treasury_cap);

    destroy(balance);
    destroy(currency);
    destroy(metadata_cap);
    abort
}

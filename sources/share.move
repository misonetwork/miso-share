// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fixed-supply currency issuance for representing equity-like ownership stakes.
///
/// ### Usage:
///
/// 1. Create a package with a `share` module containing a `Share` type
/// 2. Create a currency with `sui::coin_registry::new_currency`
/// 3. Delete the metadata cap via `finalize_and_delete_metadata_cap`
/// 4. Call `share::share::initialize` with the currency and treasury cap
/// 5. Distribute the returned balance to shareholders
module miso_share::share;

use std::type_name::{TypeName, with_defining_ids};
use sui::balance::Balance;
use sui::bcs;
use sui::coin::TreasuryCap;
use sui::coin_registry::Currency;
use sui::event::emit;

// === Constants ===

/// Fixed supply of 10,000,000.000000 tokens (6 decimal places).
const SUPPLY: u64 = 10_000_000_000_000;
/// Required number of decimal places.
const DECIMALS: u8 = 6;

/// Suffix that all valid share type names must end with.
const SHARE_TYPE: vector<u8> = b"::share::Share";

// === Errors ===

/// Currency already has non-zero supply.
const ENotZeroSupply: u64 = 0;
/// Currency's MetadataCap has not been deleted.
const EMetadataCapNotDeleted: u64 = 1;
/// Share type is invalid (must end with `::share::Share`).
const EInvalidShareType: u64 = 2;
/// Currency does not have 6 decimals.
const EInvalidDecimals: u64 = 3;
/// Currency is regulated (carries a `DenyCapV2`). Shares must be freeze-proof
/// equity, so a regulated share currency — whose issuer retains deny-list and
/// global-pause authority over holders forever — is rejected.
const ERegulatedCurrency: u64 = 4;

// === Events ===

public struct ShareInitializedEvent has copy, drop {
    share_type: TypeName,
    decimals: u8,
    supply: u64,
}

// === Public Functions ===

/// Initializes a fixed-supply share token with 10,000,000.000000 supply.
/// Validates the currency configuration, mints the fixed supply,
/// and makes the supply immutable. Returns the full token balance.
///
/// The type parameter must be a `Share` type defined in a `share` module
/// (i.e. `<address>::share::Share`).
public fun initialize<Share>(
    currency: &mut Currency<Share>,
    mut treasury_cap: TreasuryCap<Share>,
): Balance<Share> {
    // Assert the share type is valid.
    assert_valid_share_type<Share>();
    // Assert the currency's MetadataCap has been deleted,
    // which prevents currency metadata from being modified after initialization.
    assert!(currency.is_metadata_cap_deleted(), EMetadataCapNotDeleted);
    // Assert the currency is not regulated. A regulated currency has a live
    // `DenyCapV2` whose holder can deny-list or globally pause holders forever;
    // shares are meant to be freeze-proof fixed-supply equity, so making the
    // supply fixed here is not enough — the deny authority must never exist.
    assert!(!currency.is_regulated(), ERegulatedCurrency);
    // Assert the currency has the correct number of decimals.
    assert!(currency.decimals() == DECIMALS, EInvalidDecimals);
    // Assert the currency has no existing supply.
    assert!(treasury_cap.supply().value() == 0, ENotZeroSupply);

    // Mint the share balance.
    let balance = treasury_cap.mint_balance(SUPPLY);

    // Make the supply fixed.
    currency.make_supply_fixed(treasury_cap);

    emit(ShareInitializedEvent {
        share_type: with_defining_ids<Share>(),
        decimals: DECIMALS,
        supply: SUPPLY,
    });

    balance
}

//=== Assert Functions ===

/// Asserts that the share type name ends with the expected suffix
/// (`<address>::share::Share`). Public so downstream packages that hold or
/// route share types (e.g. cap inventories) can enforce the same gate this
/// package's `initialize` enforces, instead of mirroring it.
public fun assert_valid_share_type<Share>() {
    let t = with_defining_ids<Share>();
    let bytes = bcs::to_bytes(&t);
    let share_type = SHARE_TYPE;

    let bytes_len = bytes.length();
    let suffix_len = share_type.length();

    // `bytes_len >= suffix_len` always holds: every TypeName embeds a 64-char
    // hex address, so it serializes to >= 70 bytes against a 14-byte suffix.
    // If that ever stopped holding, the index arithmetic below aborts on
    // underflow (Move checked arithmetic) — the gate cannot be bypassed.
    suffix_len.do!(|i| {
        assert!(bytes[bytes_len - suffix_len + i] == share_type[i], EInvalidShareType);
    });
}

// === Test Only ===

#[test_only]
use sui::coin_registry::{Self, MetadataCap};

/// A qualifying share type: `<addr>::share::Share`. Lives in this module
/// because the suffix gate requires module `share`, struct `Share`, and
/// `coin_registry::new_currency<T>` must be called from T's defining module.
#[test_only]
public struct Share has key { id: UID }

/// A NON-qualifying type in the right module with the wrong struct name —
/// `::share::Shares` shifts the suffix window one byte and must be rejected.
#[test_only]
public struct Shares has key { id: UID }

/// Registered `Currency<Share>` + treasury + metadata cap with the given
/// decimals (callers pass 6 for valid setups, anything else to test the
/// decimals gate). Metadata cap deletion is left to the caller.
#[test_only]
public fun new_share_currency_for_testing(
    decimals: u8,
    ctx: &mut TxContext,
): (Currency<Share>, TreasuryCap<Share>, MetadataCap<Share>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (initializer, treasury_cap) = coin_registry::new_currency<Share>(
        &mut registry,
        decimals,
        b"SHR".to_string(),
        b"Share".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = coin_registry::finalize_unwrap_for_testing(initializer, ctx);
    std::unit_test::destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

#[test_only]
public fun new_shares_currency_for_testing(
    ctx: &mut TxContext,
): (Currency<Shares>, TreasuryCap<Shares>, MetadataCap<Shares>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (initializer, treasury_cap) = coin_registry::new_currency<Shares>(
        &mut registry,
        6,
        b"SHRS".to_string(),
        b"Shares".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = coin_registry::finalize_unwrap_for_testing(initializer, ctx);
    std::unit_test::destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

/// A valid-in-every-other-way `Currency<Share>` that was made **regulated**
/// (carries a live `DenyCapV2<Share>`) before finalizing. Used to prove that
/// `initialize` rejects regulated share currencies — the deny cap is returned
/// so the test can dispose of it.
#[test_only]
public fun new_regulated_share_currency_for_testing(
    ctx: &mut TxContext,
): (
    Currency<Share>,
    TreasuryCap<Share>,
    MetadataCap<Share>,
    sui::coin::DenyCapV2<Share>,
) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (mut initializer, treasury_cap) = coin_registry::new_currency<Share>(
        &mut registry,
        DECIMALS,
        b"SHR".to_string(),
        b"Share".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let deny_cap = coin_registry::make_regulated(&mut initializer, false, ctx);
    let (currency, metadata_cap) = coin_registry::finalize_unwrap_for_testing(initializer, ctx);
    std::unit_test::destroy(registry);
    (currency, treasury_cap, metadata_cap, deny_cap)
}

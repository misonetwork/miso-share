// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A type in the WRONG module (`::notshare::Share`) for testing the share
/// type-suffix gate. Has its own currency helper because
/// `coin_registry::new_currency<T>` must be called from T's defining module.
#[test_only]
module miso_share::notshare;

use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, Currency, MetadataCap};

public struct Share has key { id: UID }

public fun new_currency_for_testing(
    ctx: &mut TxContext,
): (Currency<Share>, TreasuryCap<Share>, MetadataCap<Share>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (initializer, treasury_cap) = coin_registry::new_currency<Share>(
        &mut registry,
        6,
        b"NSHR".to_string(),
        b"Not Share".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = coin_registry::finalize_unwrap_for_testing(initializer, ctx);
    std::unit_test::destroy(registry);
    (currency, treasury_cap, metadata_cap)
}

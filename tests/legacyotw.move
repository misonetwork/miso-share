// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A one-time-witness type for creating a legacy (`sui::coin`) currency in
/// tests, to prove that legacy-migrated currencies carry no recorded treasury
/// cap ID — the property `share::initialize`'s canonical-cap assert relies on
/// to reject them.
#[test_only]
module miso_share::legacyotw;

public struct LEGACYOTW has drop {}

/// Instantiate the OTW. Only possible in test code: the publish-time
/// verifier forbids instantiating a one-time witness outside `init`.
public fun new_for_testing(): LEGACYOTW { LEGACYOTW {} }

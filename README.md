# miso-share

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Move](https://img.shields.io/badge/Move-2024-black.svg)](https://docs.sui.io/concepts/sui-move-concepts)

> A [Sui Move](https://docs.sui.io/concepts/sui-move-concepts) package for fixed-supply currency issuance, designed for representing equity-like ownership stakes.

`miso_share::share::initialize` mints exactly **10,000,000.000000** tokens (6 decimals) and makes the supply immutable. It enforces a set of structural invariants at initialization to guarantee the resulting token is well-formed, tamper-proof, and freeze-proof:

- The type parameter must be `<address>::share::Share`
- The currency's `MetadataCap` must already be deleted (metadata is frozen)
- Decimals must equal 6
- Existing supply must be zero
- The currency must **not** be regulated — a regulated currency carries a
  `DenyCapV2` whose holder could deny-list or globally pause share holders
  forever, so the deny authority must never exist over a share currency

## Install

Pin to a full commit SHA (never a branch):

```toml
[dependencies]
miso_share = { git = "https://github.com/misonetwork/miso-share.git", rev = "<commit-sha>" }
```

## Usage

1. Create a package with a `share` module containing a `Share` one-time witness type.
2. Create a currency with `sui::coin_registry::new_currency`.
3. Set any desired metadata (name, symbol, icon, description), then call `finalize_and_delete_metadata_cap` to freeze it.
4. Call `miso_share::share::initialize` with the currency and treasury cap.
5. Distribute the returned `Balance<Share>` to shareholders.

### Icon URL Helper

A convenience function is provided for constructing [Walrus](https://docs.walrus.site/)-hosted icon URLs:

```move
let icon_url = miso_share::share::construct_icon_url(blob_id);
// => "walrus://<base64url-encoded blob ID>"
```

## Dependencies

| Dependency | Source |
|---|---|
| Sui Framework | Sui standard libraries |

## Build

```sh
sui move build
```

## Test

```sh
sui move test
```

## Contributing

Issues and pull requests are welcome. By contributing you agree that your contributions are licensed under the project's Apache 2.0 license.

## License

[Apache 2.0](LICENSE) © Miso Labs, Inc.

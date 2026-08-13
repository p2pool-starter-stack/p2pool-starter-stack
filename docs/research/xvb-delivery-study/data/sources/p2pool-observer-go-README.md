# Go Consensus

This repository contains a consensus-compatible reimplementation of a P2Pool internals for [Monero P2Pool](https://github.com/SChernykh/p2pool) decentralized pool.

As part of this work, several libraries to work with Monero and its cryptography are also maintained.

You may be looking for [P2Pool Observer](https://git.gammaspectra.live/P2Pool/observer) instead.

## Reporting issues

You can give feedback or report / discuss issues or provide changes on:
* [The issue tracker on git.gammaspectra.live/P2Pool/consensus](https://git.gammaspectra.live/P2Pool/consensus/issues?state=open)
* Via IRC on [#p2pool-observer@libera.chat](ircs://irc.libera.chat/#p2pool-observer) [[WebIRC](https://web.libera.chat/?nick=Guest?#p2pool-observer)] or general Monero channels
* Via Matrix on [#p2pool-observer:monero.social](https://matrix.to/#/#p2pool-observer:monero.social) or general Monero channels, or [@DataHoarder:monero.social](https://matrix.to/#/@datahoarder:monero.social)

### Security issues

Reporting potential security issues must be done privately. If you are unsure, feel free to reach out.

This can be done on:
* Via Matrix private message to [@DataHoarder:monero.social](https://matrix.to/#/@datahoarder:monero.social) 
* Email to `weebdatahoarder [at] protonmail.com`.

> **Note:** If sending mail, it's recommended to send an advisory private message to Matrix.

You must disclose usage of automated tools (fuzzers, static checkers) or AI-driven tools if used on your findings.

Reports will be reviewed and answered to. There are no bug bounties at this time, but may provide one personally to extraordinary issues.

## Libraries in this package

| Path                                          | Status                       |                                                                                             Documentation                                                                                             | Description                                                                                                                                                                                                                                                                                                                                                             |
|:----------------------------------------------|:-----------------------------|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------:|:------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| merge_mining                                  | 🛠️&#160;In&#160;development |                 [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/merge_mining)                  | Implements the [Merge Mining format and API](https://github.com/SChernykh/p2pool/blob/master/docs/MERGE_MINING.MD).                                                                                                                                                                                                                                                     |
| monero/address                                | ✅&#160;Supported             |                [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/address)                 | Implements Monero Cryptonote address decoding/encoding, and generation of Transaction Proofs                                                                                                                                                                                                                                                                            |
| monero/address/carrot                         | 🛠️&#160;In&#160;development |             [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/address/carrot)             | Implements [Carrot](https://github.com/jeffro256/carrot/blob/master/carrot.md) addressing protocol.                                                                                                                                                                                                                                                                     |
| monero/address/cryptonote                     | 🛠️&#160;In&#160;development |           [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/address/cryptonote)           | Implements legacy [CryptoNote subaddress protocol](https://www.getmonero.org/resources/research-lab/pubs/MRL-0006.pdf).                                                                                                                                                                                                                                                 |
| monero/address/wallet                         | Semi-Internal                |             [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/address/wallet)             | Implements generic View Wallet and Spend Wallet for Legacy Cryptonote and Carrot addressing protocols.<br/>Includes Tx match helpers for wallets, tx keys or tx proofs.                                                                                                                                                                                                 |
| monero/block                                  | ✅&#160;Supported             |                 [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/block)                  | Supports decoding/encoding Monero Blocks with V2 Coinbase Transactions, calculating RandomX proof of work, calculating rewards.                                                                                                                                                                                                                                         |
| monero/client                                 | ✅&#160;Supported             |                 [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/client)                 | High level Monero Daemon RPC client wrapper.                                                                                                                                                                                                                                                                                                                            |
| monero/client/rpc                             | ✅&#160;Supported             |               [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/client/rpc)               | Monero Daemon RPC client.                                                                                                                                                                                                                                                                                                                                               |
| monero/client/zmq                             | ✅&#160;Supported             |               [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/client/zmq)               | Monero Daemon ZMQ-Pub client.                                                                                                                                                                                                                                                                                                                                           |
| monero/client/levin                           | ❌&#160;Unsupported           |              [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/client/levin)              | Monero [Portable Storage](https://github.com/monero-project/monero/blob/master/docs/PORTABLE_STORAGE.md) and [Levin](https://github.com/monero-project/monero/blob/master/docs/LEVIN_PROTOCOL.md) partial implementation.                                                                                                                                               |
| monero/crypto                                 | ✅&#160;Supported             |                 [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto)                 | General Monero cryptography data types, generators and hashers, passing all upstream tests.<br/>Keccak256, Blake2b, merkle trees, signatures, hash to point and key images.                                                                                                                                                                                             |
| monero/crypto/curve                           | 🛠️&#160;In&#160;development |              [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/curve)              | Generic Field, Scalar and Point definitions and operations to work on Ed25519/Helios/Selene and others that define common interfaces.                                                                                                                                                                                                                                   |
| monero/crypto/curve25519                      | ✅&#160;Supported             |           [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/curve25519)            | Specialized Ed25519/X25519 implementation for Monero, with performant constant and variable time implementations.                                                                                                                                                                                                                                                       |
| monero/crypto/ringct                          | ✅&#160;Supported             |             [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/ringct)              | RingCT general data types, Pedersen commitments and original ring signatures.                                                                                                                                                                                                                                                                                           |
| monero/crypto/ringct/borromean                | ✅&#160;Supported&#160;port   |        [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/ringct/borromean)         | Borromean range proofs. Only verification supported.                                                                                                                                                                                                                                                                                                                    |
| monero/crypto/ringct/bulletproofs             | ✅&#160;Supported&#160;port   |       [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/ringct/bulletproofs)       | [Bulletproofs](https://eprint.iacr.org/2017/1066.pdf) and [Bulletproofs+](https://eprint.iacr.org/2020/735) range proofs.                                                                                                                                                                                                                                               |
| monero/crypto/ringct/clsag                    | ✅&#160;Supported&#160;port   |          [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/ringct/clsag)           | Implements [CLSAG RingCT](https://eprint.iacr.org/2019/654) ring signature scheme.                                                                                                                                                                                                                                                                                      |
| monero/crypto/ringct/mlsag                    | ✅&#160;Supported&#160;port   |          [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/ringct/mlsag)           | Implements [MLSAG RingCT](https://www.getmonero.org/resources/research-lab/pubs/MRL-0005.pdf) ring signature scheme.                                                                                                                                                                                                                                                    |
| monero/crypto/ringct/generalized-bulletproofs | ⏳&#160;Planned               | [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/ringct/generalized-bulletproofs) | Implements [Generalized Bulletproofs](https://github.com/simonkamp/curve-trees/blob/main/bulletproofs/generalized-bulletproofs.md).                                                                                                                                                                                                                                     |
| monero/crypto/ringct/fcmp-plus-plus           | 🛠️&#160;In&#160;development |      [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/ringct/fcmp-plus-plus)      | Implements [FCMP++](https://github.com/kayabaNerve/fcmp-plus-plus-paper/blob/develop/fcmp%2B%2B.pdf) proofs.                                                                                                                                                                                                                                                            |
| monero/crypto/multiexp                        | 🛠️&#160;In&#160;development |            [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/crypto/multiexp)             | Wrapper utilities for fast multiexponentiation in constant or variable time.                                                                                                                                                                                                                                                                                            |
| monero/proofs                                 | ✅&#160;Supported             |                 [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/proofs)                 | Implements Monero proofs, for generating and verifying Transaction proofs, Spend proofs.                                                                                                                                                                                                                                                                                |
| monero/randomx                                | ✅&#160;Supported             |                [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/randomx)                 | Implements [RandomX](https://github.com/tevador/RandomX/blob/master/doc/specs.md) proof of work, with pure Go implementation and optional C library.                                                                                                                                                                                                                    |
| monero/cryptonight                            | ✅&#160;Supported             |              [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/cryptonight)               | Implements [CryptoNight](https://docs.getmonero.org/proof-of-work/cryptonight/) proof of work, with variants v0, [v1](https://github.com/monero-project/monero/pull/3253), [v2](https://github.com/monero-project/monero/pull/4218), [R](https://github.com/monero-project/monero/pull/5126) supported, with pure Go.<br/>Aimed for verification (not mining) purposes. |
| monero/transaction                            | ✅&#160;Supported             |              [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/monero/transaction)               | Allows decoding/encoding and verifying transactions from binary, along its proofs on V1 and V2 transactions for all supported ring signatures and range proofs. Supports pruning.                                                                                                                                                                                       |
| p2pool/mempool                                | ✅&#160;Supported             |                [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/p2pool/mempool)                 | Mempool selection algorithm for P2Pool.                                                                                                                                                                                                                                                                                                                                 |
| p2pool/p2p                                    | ✅&#160;Supported             |                  [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/p2pool/p2p)                   | P2Pool Consensus P2P implementation. For go-p2pool.                                                                                                                                                                                                                                                                                                                     |
| p2pool/sidechain                              | ✅&#160;Supported             |               [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/p2pool/sidechain)                | P2Pool Consensus SideChain, compatible across all P2Pool versions and hard forks.<br/>Passes all upstream tests. For go-p2pool and Observer.                                                                                                                                                                                                                            |
| p2pool/stratum                                | ✅&#160;Supported             |                [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/p2pool/stratum)                 | P2Pool Stratum implementation, supporting multiple addresses. For go-p2pool.                                                                                                                                                                                                                                                                                            |
| types                                         | ✅&#160;Supported             |                     [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/types)                     | General data types to work with 256-bit hashes or other fixed bytes, proof of work checking and 128-bit network difficulty.                                                                                                                                                                                                                                             |
| utils                                         | Semi-Internal                |                     [![Go Reference](https://pkg.go.dev/badge/git.gammaspectra.live/P2Pool/consensus/v5.svg)](https://pkg.go.dev/git.gammaspectra.live/P2Pool/consensus/v5/utils)                     | Utilities to decode or work with specialized Monero types.                                                                                                                                                                                                                                                                                                              |

### Support Status Description
* **✅ Supported**: Fully supported, maintained, and regularly/automatically tested. They are built for external consumption. Will follow the semver of the main package.
* **✅ Supported port**: Fully supported, maintained, and regularly/automatically tested. They are built for external consumption. Will follow the semver of the main package. These were ported from [monero-oxide](https://github.com/monero-oxide/monero-oxide), unless specified.
* **Semi-Internal**: Supported, when used along with other parts of this package. Not supported when used independently.
* **Internal**: Not supported when used externally. Supported within the package.
* **🛠️ In Development**: Currently in development or not finished. It is not guaranteed to not break, even across minor patches. Use at your own discretion.
* **⏳ Planned**: Planned to be developed.
* **❌ Unsupported**: Not supported. Package may be deprecated or not currently developed.

> **Note:** Project is automatically tested under Linux for _amd64_ and _arm64_ architectures, with normal, _purego_, and _cgo_ flavors. 
> Other platforms are tested manually. 32-bit platforms should work but are not supported, but may receive fixes as needed.

## Other maintained external libraries

| Package                                                             |            Status            | Description                                                                                                                                                                                                                                                                                               |
|:--------------------------------------------------------------------|:----------------------------:|:----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| [go-p2pool](https://git.gammaspectra.live/P2Pool/go-p2pool)         |       ✅&#160;Supported       | Alternative P2Pool daemon implementation in Go.<br/>Supports full consensus and mining, with similar arguments. Able to run P2Pool seed nodes.                                                                                                                                                            |
| [go-randomx](https://git.gammaspectra.live/P2Pool/go-randomx)       |       ✅&#160;Supported       | Implements pure Go [RandomX](https://github.com/tevador/RandomX/blob/master/doc/specs.md), with JIT for amd64 and native support for more architectures, and purego implementation for WASM.<br/>Achieves ~90% speed of equivalent full mode under `amd64`, aimed for verification (not mining) purposes. |
| [edwards25519](https://git.gammaspectra.live/P2Pool/edwards25519)   |       ✅&#160;Supported       | Implements the edwards25519 elliptic curve, with extensions to support Monero operations efficiently.<br/>Builds on top of [FiloSottile/edwards25519](https://github.com/FiloSottile/edwards25519) as a fork.                                                                                             |
| [helioselene](https://git.gammaspectra.live/P2Pool/helioselene)     | 🛠️&#160;In&#160;Development | Implements [Helio-Selene](https://gist.github.com/tevador/4524c2092178df08996487d4e272b096), Elliptic curve tower-cycle for Curve25519.<br/>Efficient _purego_ implementation using formally proven field element operations.                                                                             |
| [monero-base58](https://git.gammaspectra.live/P2Pool/monero-base58) |       ✅&#160;Supported       | Efficient Monero's Base58 encoder/decoder.                                                                                                                                                                                                                                                                |


## SemVer and usage in other projects

This package follows [SemVer v2](https://semver.org/spec/v2.0.0.html) from _v5.x.x_ onwards, with the following additions or exceptions:

* MINOR version of 0 indicates an in-development version. In this case, PATCH indicates API changes, additions, or breakage. Once MINOR version is increased to one or above, normal SemVer resumes.
* Untagged or development branches are not covered by SemVer versions.
* Security releases MAY break backwards compatibility.
* **❌ Unsupported**, **🛠️ In Development**, **Semi-Internal** or **Internal** subpackages are not covered by the SemVer version.

## Donations
This project is provided for everyone to use, for free. Any support is appreciated.

Donate to support this project, its development, and running the Observer Instances on
[4AeEwC2Uik2Zv4uooAUWjQb2ZvcLDBmLXN4rzSn3wjBoY8EKfNkSUqeg5PxcnWTwB1b2V39PDwU9gaNE5SnxSQPYQyoQtr7](monero:4AeEwC2Uik2Zv4uooAUWjQb2ZvcLDBmLXN4rzSn3wjBoY8EKfNkSUqeg5PxcnWTwB1b2V39PDwU9gaNE5SnxSQPYQyoQtr7?tx_description=P2Pool.Observer)

You can also use the OpenAlias `p2pool.observer` directly on the GUI.

## Development notes

### Running tests

```shell
cd path/to/project/consensus
MONEROD_RPC_URL=http://127.0.0.1:18081
MONEROD_ZMQ_URL=tcp://127.0.0.1:18083
go test -v ./...
```

#### Initialize test data

Several test data is provided outside the repository tree, but is verified with saved hashes.
Monero crypto tests and P2Pool crypto and sidechain tests will be downloaded. Requires `curl` and `sha256sum` installed.

> **Note:** This only needs to be run once, or when new test data is added.

```shell
cd path/to/project/consensus
./testdata/setup.sh
```

### Running linters

Install [golangci-lint](https://golangci-lint.run/docs/welcome/install/#local-installation)

The config is available in-tree at [.golangci.yml](.golangci.yml)

```shell
cd path/to/project/consensus
golangci-lint run ./...
go vet ./...
```

### Requirements

Go 1.26

By default, CGO is not necessary, so `CGO_ENABLED=0` is recommended. You may use the `purego` build flag to disable any assembly or architecture specific optimizations.

This library supports both [go-RandomX library](https://git.gammaspectra.live/P2Pool/go-randomx) and the [C++ RandomX reference counterpart](https://github.com/tevador/RandomX).

By default, the Golang library will be used, without special requirements.

You can enable the C++ library if by using CGO and the Go compile tag `enable_randomx_library` and use `CGO_ENABLED=1`.
You must have the library installed or done via the command below:
```bash
$ git clone --depth 1 --branch v2.0.1 https://github.com/tevador/RandomX.git /tmp/RandomX && cd /tmp/RandomX && \
    mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -D CMAKE_INSTALL_PREFIX:PATH=/usr && \
    make -j$(nproc) && \
    sudo make install && \
    cd ../ && \
    rm -rf /tmp/RandomX
```
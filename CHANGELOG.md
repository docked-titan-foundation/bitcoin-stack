# 1.0.0-beta.1 (2026-07-24)


### Bug Fixes

* **ci:** keep Chart.yaml descriptions under the yamllint line limit ([8377915](https://github.com/docked-titan-foundation/bitcoin-stack/commit/8377915213b520e264a90fbf94ffd856f42b52a6))
* **ci:** pipefail so a failed semantic-release fails the release job ([d2382f0](https://github.com/docked-titan-foundation/bitcoin-stack/commit/d2382f0c1ebc42107c8d649e900ef1a432bfeaf1))
* **ci:** skip the weekly rebuild when there is no stable release ([6f1c55e](https://github.com/docked-titan-foundation/bitcoin-stack/commit/6f1c55e0da97e17744a0d14b2c4f08d521576d80)), closes [#1](https://github.com/docked-titan-foundation/bitcoin-stack/issues/1)
* **license:** ship the GPL-3.0 text inside each packaged chart ([3e79fe4](https://github.com/docked-titan-foundation/bitcoin-stack/commit/3e79fe452b0b64e95e2ff23405b1de81255d7eee))
* **node:** quote the ESO rpc-password value so externalSecret renders valid YAML ([d90f2ed](https://github.com/docked-titan-foundation/bitcoin-stack/commit/d90f2edf4e260e6ccecf0f014b1b1c355e67f90c))
* **node:** treat a null config option as unset under the Core guard ([ca14538](https://github.com/docked-titan-foundation/bitcoin-stack/commit/ca1453832d1d10d90154fc00a28ee2bc3de631f9))
* **node:** use external-secrets.io/v1 for the ExternalSecret ([829500a](https://github.com/docked-titan-foundation/bitcoin-stack/commit/829500a3d90b928b6f4d84ce3b9f53ac932a6a8b))
* **pool:** correct the stale public-pool image digest ([f1468a0](https://github.com/docked-titan-foundation/bitcoin-stack/commit/f1468a0dc5b09622c3d1e8a3dcd07f1858752bcd))
* **pool:** pin public-pool and ckpool to v1.0.0 ([46b8c21](https://github.com/docked-titan-foundation/bitcoin-stack/commit/46b8c21d2214d00e7533b24cb8b88af760bb7631))
* **pool:** treat a regtest node as synced in the wait-for-node-sync gate ([ec1ccdc](https://github.com/docked-titan-foundation/bitcoin-stack/commit/ec1ccdc4feeddd87d2ac9b8801bf3d4a9e7f9e06))
* **release:** emit a valid SemVer for the local build version ([7a229d0](https://github.com/docked-titan-foundation/bitcoin-stack/commit/7a229d0a24566252e747a4a59b1c60fbc9f088c7))
* **release:** land version-matrix rows in the correct README table ([f728d73](https://github.com/docked-titan-foundation/bitcoin-stack/commit/f728d73f3412d7fac34362e5eb3a16241e557f78)), closes [#2](https://github.com/docked-titan-foundation/bitcoin-stack/issues/2)
* **release:** make update-versions.sh executable ([30ba819](https://github.com/docked-titan-foundation/bitcoin-stack/commit/30ba8193e137f704e277c0a92b196fef76c40bf0))
* **stack:** refuse to install with both subcharts disabled ([cb25e10](https://github.com/docked-titan-foundation/bitcoin-stack/commit/cb25e10f093eefeb3bec7f9a1ad1e59420965f5b))


### Features

* **node:** add custom implementation for bring-your-own images ([5ae98f6](https://github.com/docked-titan-foundation/bitcoin-stack/commit/5ae98f610e2cc28634098e44b6ce5fa778882e56))
* **pool:** default ckpool to the hardened docked-titan-foundation image ([092670c](https://github.com/docked-titan-foundation/bitcoin-stack/commit/092670c4f93655966ef9632605f5c69bf5bd82b7))
* **pool:** hold the pool in an init container until the node is synced ([8f68c49](https://github.com/docked-titan-foundation/bitcoin-stack/commit/8f68c490632f45895a521dc0ca83944048755f25))
* **stack:** hardened Helm chart for a Bitcoin node and mining pool ([5a1be7d](https://github.com/docked-titan-foundation/bitcoin-stack/commit/5a1be7d9733477a7e78ef9ef60ef55d4f2264255))

# 1.0.0-beta.1 (2026-07-24)


### Bug Fixes

* **ci:** keep Chart.yaml descriptions under the yamllint line limit ([8377915](https://github.com/docked-titan-foundation/bitcoin-stack/commit/8377915213b520e264a90fbf94ffd856f42b52a6))
* **ci:** pipefail so a failed semantic-release fails the release job ([d2382f0](https://github.com/docked-titan-foundation/bitcoin-stack/commit/d2382f0c1ebc42107c8d649e900ef1a432bfeaf1))
* **ci:** skip the weekly rebuild when there is no stable release ([6f1c55e](https://github.com/docked-titan-foundation/bitcoin-stack/commit/6f1c55e0da97e17744a0d14b2c4f08d521576d80)), closes [#1](https://github.com/docked-titan-foundation/bitcoin-stack/issues/1)
* **license:** ship the GPL-3.0 text inside each packaged chart ([3e79fe4](https://github.com/docked-titan-foundation/bitcoin-stack/commit/3e79fe452b0b64e95e2ff23405b1de81255d7eee))
* **node:** quote the ESO rpc-password value so externalSecret renders valid YAML ([d90f2ed](https://github.com/docked-titan-foundation/bitcoin-stack/commit/d90f2edf4e260e6ccecf0f014b1b1c355e67f90c))
* **node:** treat a null config option as unset under the Core guard ([ca14538](https://github.com/docked-titan-foundation/bitcoin-stack/commit/ca1453832d1d10d90154fc00a28ee2bc3de631f9))
* **node:** use external-secrets.io/v1 for the ExternalSecret ([829500a](https://github.com/docked-titan-foundation/bitcoin-stack/commit/829500a3d90b928b6f4d84ce3b9f53ac932a6a8b))
* **pool:** correct the stale public-pool image digest ([f1468a0](https://github.com/docked-titan-foundation/bitcoin-stack/commit/f1468a0dc5b09622c3d1e8a3dcd07f1858752bcd))
* **pool:** pin public-pool and ckpool to v1.0.0 ([46b8c21](https://github.com/docked-titan-foundation/bitcoin-stack/commit/46b8c21d2214d00e7533b24cb8b88af760bb7631))
* **pool:** treat a regtest node as synced in the wait-for-node-sync gate ([ec1ccdc](https://github.com/docked-titan-foundation/bitcoin-stack/commit/ec1ccdc4feeddd87d2ac9b8801bf3d4a9e7f9e06))
* **release:** emit a valid SemVer for the local build version ([7a229d0](https://github.com/docked-titan-foundation/bitcoin-stack/commit/7a229d0a24566252e747a4a59b1c60fbc9f088c7))
* **release:** land version-matrix rows in the correct README table ([f728d73](https://github.com/docked-titan-foundation/bitcoin-stack/commit/f728d73f3412d7fac34362e5eb3a16241e557f78)), closes [#2](https://github.com/docked-titan-foundation/bitcoin-stack/issues/2)
* **release:** make update-versions.sh executable ([30ba819](https://github.com/docked-titan-foundation/bitcoin-stack/commit/30ba8193e137f704e277c0a92b196fef76c40bf0))
* **stack:** refuse to install with both subcharts disabled ([cb25e10](https://github.com/docked-titan-foundation/bitcoin-stack/commit/cb25e10f093eefeb3bec7f9a1ad1e59420965f5b))


### Features

* **node:** add custom implementation for bring-your-own images ([5ae98f6](https://github.com/docked-titan-foundation/bitcoin-stack/commit/5ae98f610e2cc28634098e44b6ce5fa778882e56))
* **pool:** default ckpool to the hardened docked-titan-foundation image ([092670c](https://github.com/docked-titan-foundation/bitcoin-stack/commit/092670c4f93655966ef9632605f5c69bf5bd82b7))
* **pool:** hold the pool in an init container until the node is synced ([8f68c49](https://github.com/docked-titan-foundation/bitcoin-stack/commit/8f68c490632f45895a521dc0ca83944048755f25))
* **stack:** hardened Helm chart for a Bitcoin node and mining pool ([5a1be7d](https://github.com/docked-titan-foundation/bitcoin-stack/commit/5a1be7d9733477a7e78ef9ef60ef55d4f2264255))

# Changelog

All notable changes are generated by semantic-release.

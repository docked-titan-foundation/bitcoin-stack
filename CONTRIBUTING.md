# Contributing to bitcoin-stack

Contributions are welcome! Please read this guide to get started.

## Requirements

- Docker 20.10+ (only for `mise run test`, which spins up a kind cluster)
- [mise](https://mise.jdx.dev) — installs the pinned chart toolchain (helm, ct, kubeconform, kind, yamllint)
- [pre-commit](https://pre-commit.com) (install via `pip install pre-commit` or `brew install pre-commit`)

## Development Setup

1. Clone the repository:

   ```bash
   git clone https://github.com/docked-titan-foundation/bitcoin-stack.git
   cd bitcoin-stack
   ```

2. Install pre-commit hooks:

   ```bash
   pip install pre-commit   # or: brew install pre-commit
   pre-commit install
   ```

3. Install the pinned toolchain (see `.mise.toml`):

   ```bash
   mise install
   ```

4. Lint and render:

   ```bash
   mise run lint       # ct lint + yamllint + shellcheck
   mise run template   # render the matrix through kubeconform; assert the guards fire
   ```

5. Test for real:

   ```bash
   mise run test       # kind + a live regtest node and pool, end to end
   mise run precommit
   ```

   `mise run test` is the one that matters. A chart that renders is not a chart
   that works: this installs the stack on a regtest node (ready in seconds, not
   days) and asserts that bitcoind answers RPC on the generated credential, that
   the pool authenticated and pulled a block template, that a new block reaches the
   pool over ZMQ, and that the stratum port accepts a miner.

   `mise tasks` lists everything available.

## Ways to Contribute

- Report bugs
- Suggest new features
- Improve documentation
- Submit pull requests

## Pull Request Process

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Run pre-commit checks:

   ```bash
   pre-commit run --all-files
   ```

5. Commit your changes (`git commit -m 'Add my feature'`)
6. Push to your fork (`git push origin feature/my-feature`)
7. Open a Pull Request targeting the **`beta`** branch

## Beta Testing

For pre-release beta testing, all pull requests must target the **beta** branch.
The beta branch receives pre-release versions before changes are merged into the
main branch for stable releases.

- To test beta releases, pull the latest changes from the beta branch
- Beta versions are published with pre-release tags (e.g., `1.5.0-beta.1`)
- All features and fixes intended for the next stable release should first be merged
  into the beta branch for testing
- Once validated, changes will be promoted from beta to main via the release process

## Semantic Release (SR) Process

This project uses [Semantic Release](https://semantic-release.gitbook.io/) for automated
versioning and package publishing. The release process follows conventional commit
standards with Angular-style formatting.

### Branch Strategy

- **`main` branch**: Stable releases only. Direct pushes to main are restricted;
  all changes flow through the beta branch first.
- **`beta` branch**: Pre-release testing ground. Features and fixes are merged here
  for beta testing before promotion to main.

### Versioning

One version covers all three charts: `scripts/update-versions.sh` writes it into
every `Chart.yaml` (and into the umbrella's dependency pins, which must match or
`helm dependency build` fails).

- **Patch** (`1.0.X`): a pinned image digest bump, a bug fix in a template
- **Minor** (`1.X.0`): a new value, a new capability, a node image version bump
- **Major** (`X.0.0`): a breaking values change — a renamed or removed value, a
  changed default that alters a running node's behaviour, or a new guard that
  refuses a configuration that previously installed

Treat that last one seriously. A chart's values are its API, and someone's node is
running on them.

Beta releases use pre-release tags (e.g., `1.5.0-beta.0`).

### Conventional Commits

All commits must follow the [Conventional Commits](https://www.conventionalcommits.org/)
specification with Angular-style formatting:

- Format: `<type>(<scope>): <description>`
- Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`, `revert`
- Scope indicates the affected area (e.g., `node`, `pool`, `stack`, `ci`, `dependencies`)
- Breaking changes must be indicated with `!` after type/scope or `BREAKING CHANGE:` in footer
- Example: `feat(pipeline): add beta branch support`

### Commit Types and Release Rules

Commits are categorized into two groups for release triggering:

**Version-bumping commits** — these produce a release:

- `feat` — a new value, a new capability, a node image version bump
  (e.g., `feat(node): support Bitcoin Core 32`)
- `fix` — a template bug, a digest bump
  (e.g., `fix(pool): pin public-pool to a new digest`)
- `feat!` or a `BREAKING CHANGE:` footer — a breaking values change

**Non-release commits** — These improve the project without triggering a release. Use for:

- `chore` — maintenance tasks, dependency updates (non-sub-tool), CI/CD config
- `refactor` — code restructuring without functional changes
- `docs` — documentation updates
- `style` — formatting, lint fixes
- `test` — test additions/updates
- `ci` — CI configuration updates
- `build` — build system changes

### Release Triggers

- A new release is triggered automatically on push to `main` or `beta` branches
- `semantic-release` analyzes commits since the last tag to determine the version bump
- The version matrix in the README is regenerated from the charts' pinned image tags
- All three `Chart.yaml` files and the umbrella's dependency pins are updated automatically
- Changelog is auto-generated from commit messages
- The chart is packaged, tested on a real kind cluster, scanned, pushed to GHCR as an
  OCI artifact, and signed **by digest**
- An SPDX SBOM is generated and attested for each release

### Automated Dependency Updates (Renovate)

This project uses [Renovate](https://docs.renovatebot.com/) for automated dependency
management. Renovate opens PRs against the **`beta`** branch when new versions are
available. The commit type is chosen per update level:

| Update type | Commit produced | Release triggered |
|-------------|-----------------|-------------------|
| **bitcoind image** digest (`images.knots` / `images.core`) | `feat(node): ...` | minor |
| **Pool image** digest (`image.digest`) | `fix(pool): ...` | patch |
| GitHub Actions / npm | `chore(dependencies): ...` | none |

Merge the Renovate PR after CI passes — **except for node and pool image bumps**.
Those are never auto-merged and carry a `review-required` label:

- a **bitcoind** bump is consensus-critical code, and rolling it *backwards* across
  a major version is not possible without a reindex;
- a **pool** bump changes the code that constructs the coinbase output — it decides
  where a found block's reward is paid.

Read the upstream diff before merging either.

## Digest Pinning

Every image this chart can run is pinned by `sha256` digest, never by tag alone. A
tag is a mutable pointer — the same tag can point at different bytes tomorrow — and
these processes hold the keys to money.

The charts enforce this themselves: `helm template` **fails** on an unpinned image
unless `safety.allowUnpinnedImage: true` is set deliberately, and
`scripts/template.sh` asserts on the rendered output that no image escaped without
a digest. Do not relax either.

ckpool deliberately has **no default image**. Upstream publishes source only, and
every ckpool image on Docker Hub is an unaudited personal build. Do not add one.

## Coding Standards

- All files must pass pre-commit hooks
- Charts must pass `ct lint` and render cleanly through `kubeconform -strict`
- Every rendered container must be non-root, drop all capabilities, and run a
  read-only root filesystem — `scripts/template.sh` asserts this
- Every safety guard must have a negative test proving it *refuses* the bad
  configuration. A guard without a test that it fires is not a guard
- New values need a comment explaining the consequence of getting them wrong

## Pipeline Flow

bitcoin-stack uses a gated pipeline for quality and security:

```text
lint
 └─▶ release
       └─▶ package (local only)
             └─▶ render matrix + hardening + guard assertions
                   └─▶ e2e on kind (real node + real pool, regtest)
                         └─▶ config scan (CRITICAL/HIGH = fail)
                               └─▶ SBOM generation
                                     └─▶ push (first public appearance)
                                           └─▶ provenance
                                                 └─▶ sign + attest SBOM
```

| Gate | Description |
|------|-------------|
| **Lint** | `ct lint`, yamllint, shellcheck, commitlint |
| **Release** | Semantic versioning on main/beta (GPG-signed commits by `s-release[bot]`) |
| **Package** | `helm package` — no push |
| **Render** | The whole values matrix through `kubeconform -strict`; asserts every container is non-root/capless/read-only and every image is digest-pinned; asserts each safety guard **refuses** its bad configuration |
| **E2E** | kind cluster, stack installed on regtest: bitcoind answers RPC on the generated credential, the pool authenticates and pulls a template, a block reaches it over ZMQ, stratum accepts a miner |
| **Config scan** | Trivy misconfiguration scan of the rendered manifests (CRITICAL/HIGH = fail) |
| **SBOM** | SPDX JSON Software Bill of Materials |
| **Push** | First public appearance, to GHCR as an OCI artifact |
| **Provenance** | SLSA build provenance attestation |
| **Sign** | Cosign keyless signature **by digest**, plus a signed SBOM attestation |

## License

By contributing, you agree that your contributions will be licensed under the
GNU General Public License v3.0.

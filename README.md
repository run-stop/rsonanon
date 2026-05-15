# rsonanon

**rsonanon** is an offline tool for anonymizing JSON data before sharing it with
colleagues, filing bug reports, or importing it into third-party services — without
ever sending the original data anywhere.  Everything runs locally on your machine.

It replaces sensitive values with realistic fakes while keeping the JSON structure
exactly intact: keys, nesting, arrays, and value types are all preserved, so
downstream code, schemas, and tooling continue to work unchanged.

- **Strings** are replaced with semantically appropriate fakes — emails stay
  emails, UUIDs stay UUIDs, IP addresses stay IP addresses, dates stay dates,
  phone numbers stay phone numbers, and so on.
- **Numbers** are replaced with values of the same magnitude and sign.
- **Booleans** and **nulls** keep their type (nulls can optionally be replaced too).
- **Output is deterministic** when a seed is supplied, so the same input always
  produces the same anonymized output — useful for reproducible test fixtures.
- **Multi-core acceleration** — large JSON arrays (32+ elements) are automatically
  split across worker threads (up to 8, capped at the number of available CPUs),
  so bulk anonymization of big datasets is fast.

## Usage

```
rsonanon [OPTIONS]

Options:
  --in:<file>             Input JSON file.  Defaults to stdin.
  --out:<file>            Output JSON file. Defaults to stdout.
  --pretty:on|off         Pretty-print output. Default: on.
  --seed:<integer>        Deterministic numeric seed.
  --seed-text:<text>      Deterministic text seed (hashed to integer internally).
  --preserve-null:on|off  Keep null values as null. Default: on.
  --help                  Show this help.
```

### Examples

```bash
# Anonymize a file, write to another file
rsonanon --in:input.json --out:anon.json

# Reproducible output across runs (same seed → same result)
rsonanon --in:input.json --out:anon.json --seed-text:project-a

# Pipe-friendly: read from stdin, compact output
cat input.json | rsonanon --pretty:off > anon.json

# Replace nulls instead of preserving them
rsonanon --in:input.json --preserve-null:off --out:anon.json
```

### Sample transformation

Input (`input.json`):
```json
{
  "id": "a1b2c3d4-e5f6-4789-abcd-ef1234567890",
  "firstName": "Alice",
  "lastName": "Wonderland",
  "email": "alice.wonderland@company.example.com",
  "phone": "+1-202-555-0173",
  "dateOfBirth": "1985-03-22",
  "age": 39,
  "address": {
    "street": "742 Evergreen Terrace",
    "city": "Springfield",
    "state": "IL",
    "postcode": "62704",
    "country": "United States"
  },
  "ipAddress": "203.0.113.45",
  "website": "https://alice.example.com/profile",
  "active": true
}
```

Output (`rsonanon --in:input.json --seed-text:readme-example`):
```json
{
  "active": false,
  "address": {
    "city": "Riverton",
    "country": "Australia",
    "postcode": "46135",
    "state": "MA",
    "street": "5183 Davis Street"
  },
  "age": 52,
  "dateOfBirth": "2009-05-16",
  "email": "quinn.hall41@example.test",
  "firstName": "Taylor",
  "fullName": "Jamie Davis",
  "ipAddress": "10.13.66.250",
  "lastName": "Hall",
  "phone": "+1-555-246-9304",
  "website": "https://bluebird-systems.example.test/docs"
}
```

---

## Building locally

### Prerequisites

- **Rust toolchain** — install via [rustup](https://rustup.rs/):
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

### Native build (development)

```bash
cargo build --release
# Binary: target/release/rsonanon
```

### Statically linked Linux builds (musl)

Install [`cross`](https://github.com/cross-rs/cross) (requires Docker):

```bash
cargo install cross --locked
```

| Platform | Target triple | Command |
|---|---|---|
| Linux x86_64 | `x86_64-unknown-linux-musl` | `cross build --release --target x86_64-unknown-linux-musl` |
| Linux ARM64 | `aarch64-unknown-linux-musl` | `cross build --release --target aarch64-unknown-linux-musl` |

Output binaries have **zero dynamic library dependencies** and run on any Linux
distribution (Debian, Ubuntu, Fedora, …) without additional packages.

```bash
# Verify no dynamic deps
ldd target/x86_64-unknown-linux-musl/release/rsonanon
# → statically linked
```

### Windows builds (static MSVC CRT)

Add the required Rust targets first:

```bash
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-pc-windows-msvc
```

| Platform | Target triple | Command |
|---|---|---|
| Windows x86_64 | `x86_64-pc-windows-msvc` | `cargo build --release --target x86_64-pc-windows-msvc` |
| Windows ARM64 | `aarch64-pc-windows-msvc` | `cargo build --release --target aarch64-pc-windows-msvc` |

`.cargo/config.toml` already injects `-C target-feature=+crt-static` for both
MSVC targets, so the resulting `.exe` has no MSVC runtime DLL dependencies.

```
target/x86_64-pc-windows-msvc/release/rsonanon.exe
target/aarch64-pc-windows-msvc/release/rsonanon.exe
```

> **Note:** cross-compiling for `aarch64-pc-windows-msvc` requires a Windows host
> or a Windows GitHub Actions runner.

### Building .deb and .rpm packages locally

Install the packaging tools:

```bash
cargo install cargo-deb --locked
cargo install cargo-generate-rpm --locked
```

Build for a specific target (pass `--no-build` to skip recompiling):

```bash
# .deb — Debian / Ubuntu
cross build --release --target x86_64-unknown-linux-musl
cargo deb --no-build --target x86_64-unknown-linux-musl
# → target/x86_64-unknown-linux-musl/debian/rsonanon_0.1.0_amd64.deb

cross build --release --target aarch64-unknown-linux-musl
cargo deb --no-build --target aarch64-unknown-linux-musl
# → target/aarch64-unknown-linux-musl/debian/rsonanon_0.1.0_arm64.deb

# .rpm — Fedora
cross build --release --target x86_64-unknown-linux-musl
cargo generate-rpm --target x86_64-unknown-linux-musl
# → target/x86_64-unknown-linux-musl/generate-rpm/rsonanon-0.1.0-1.x86_64.rpm

cross build --release --target aarch64-unknown-linux-musl
cargo generate-rpm --target aarch64-unknown-linux-musl
# → target/aarch64-unknown-linux-musl/generate-rpm/rsonanon-0.1.0-1.aarch64.rpm
```

---

## Releases

Pushing a `vX.Y.Z` tag triggers the GitHub Actions release workflow, which
automatically builds and publishes all packages:

| File | Platform |
|---|---|
| `rsonanon_X.Y.Z_amd64.deb` | Debian / Ubuntu — x86_64 |
| `rsonanon_X.Y.Z_arm64.deb` | Debian / Ubuntu — ARM64 |
| `rsonanon-X.Y.Z-1.x86_64.rpm` | Fedora — x86_64 |
| `rsonanon-X.Y.Z-1.aarch64.rpm` | Fedora — ARM64 |
| `rsonanon-windows-x86_64.exe` | Windows 64-bit |
| `rsonanon-windows-arm64.exe` | Windows on ARM |

---

## Running tests

```bash
cargo build --release
bash tests/run_tests.sh
```

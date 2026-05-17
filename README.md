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
  --in:<file>               Input JSON file.  Defaults to stdin.
  --out:<file>              Output JSON file. Defaults to stdout.
  --pretty:on|off           Pretty-print output. Default: on.
  --seed:<integer>          Deterministic numeric seed.
  --seed-text:<text>        Deterministic text seed (hashed to integer internally).
  --preserve-null:on|off    Keep null values as null. Default: on.
  --preserve-order:on|off   Preserve original JSON key order. Default: on.
                            Use off to sort keys alphabetically instead.
  --help                    Show this help.
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

# Sort keys alphabetically instead of preserving original order
rsonanon --in:input.json --preserve-order:off --out:anon.json
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
  "id": "51b9fb7f-cec2-47a0-8a45-3863df220790",
  "firstName": "Avery",
  "lastName": "Davis",
  "email": "nora.wilson68@example.test",
  "phone": "+1-555-004-2869",
  "dateOfBirth": "2021-12-11",
  "age": 76,
  "address": {
    "street": "9776 Davis Boulevard",
    "city": "Riverton",
    "state": "CO",
    "postcode": "60851",
    "country": "United Kingdom"
  },
  "ipAddress": "10.81.135.13",
  "website": "https://oakridge-partners.example.test/docs",
  "active": true
}
```

Output (`rsonanon --in:input.json --seed-text:readme-example --preserve-order:off`):
```json
{
  "active": true,
  "address": {
    "city": "Riverton",
    "country": "United Kingdom",
    "postcode": "60851",
    "state": "CO",
    "street": "9776 Davis Boulevard"
  },
  "age": 76,
  "dateOfBirth": "2021-12-11",
  "email": "nora.wilson68@example.test",
  "firstName": "Avery",
  "id": "51b9fb7f-cec2-47a0-8a45-3863df220790",
  "ipAddress": "10.81.135.13",
  "lastName": "Davis",
  "phone": "+1-555-004-2869",
  "website": "https://oakridge-partners.example.test/docs"
}
```

---

## Building locally

### Prerequisites

- **Rust toolchain** — install via [rustup](https://rustup.rs/):
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

### Build all targets at once

The commands below compile every release artifact — Linux musl binaries, Windows
executables, and all Linux packages — from a single Linux machine.

**One-time setup:**

```bash
# Cargo packaging tools
cargo install cross --locked
cargo install cargo-deb --locked
cargo install cargo-generate-rpm --locked

# llvm-mingw: clang-based cross-compiler for Windows targets (ARM64 + x86_64).
# Download the latest release from https://github.com/mstorsjo/llvm-mingw/releases
# and add its bin/ to PATH, e.g.:
LLVM_MINGW=llvm-mingw-20240619-ucrt-ubuntu-20.04-x86_64
curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/20240619/${LLVM_MINGW}.tar.xz" \
  | tar -xJ
export PATH="$PWD/${LLVM_MINGW}/bin:$PATH"   # add to ~/.bashrc to make permanent

# Rust targets
rustup target add \
  x86_64-unknown-linux-musl \
  aarch64-unknown-linux-musl \
  x86_64-pc-windows-gnullvm \
  aarch64-pc-windows-gnullvm
```

**Build everything:**

```bash
# Linux — statically linked musl binaries
cross build --release --target x86_64-unknown-linux-musl
cross build --release --target aarch64-unknown-linux-musl

# Windows — cross-compiled from Linux via llvm-mingw
cargo build --release --target x86_64-pc-windows-gnullvm
cargo build --release --target aarch64-pc-windows-gnullvm

# Linux packages (.deb + .rpm)
cargo deb         --no-build --target x86_64-unknown-linux-musl
cargo deb         --no-build --target aarch64-unknown-linux-musl
cargo generate-rpm         --target x86_64-unknown-linux-musl
cargo generate-rpm         --target aarch64-unknown-linux-musl
```

---

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

### macOS builds

macOS binaries are built natively on GitHub-hosted macOS runners (no cross-compilation
tooling required — the Rust toolchain ships with the necessary LLVM back-ends).

```bash
rustup target add x86_64-apple-darwin aarch64-apple-darwin
```

| Platform | Target triple | Command |
|---|---|---|
| macOS Intel | `x86_64-apple-darwin` | `cargo build --release --target x86_64-apple-darwin` |
| macOS Apple Silicon | `aarch64-apple-darwin` | `cargo build --release --target aarch64-apple-darwin` |

```
target/x86_64-apple-darwin/release/rsonanon
target/aarch64-apple-darwin/release/rsonanon
```

> **macOS Gatekeeper** — release binaries are not code-signed, so macOS quarantines
> them when downloaded from the internet. Run this once after downloading to allow
> execution:
> ```bash
> xattr -d com.apple.quarantine rsonanon-macos-arm64   # adjust filename as needed
> ```
> Alternatively, right-click the file in Finder and choose **Open**.

### Windows builds (cross-compiled from Linux)

Windows executables are built using the `gnullvm` ABI — a clang/LLVM-based MinGW
toolchain that produces self-contained `.exe` files with no runtime DLL dependencies
(via `-C target-feature=+crt-static`). Everything runs from Linux; no Windows host
or MSVC installation required.

**Install [llvm-mingw](https://github.com/mstorsjo/llvm-mingw/releases)** and add its
`bin/` directory to `PATH` (see the "Build all targets at once" section above), then:

```bash
rustup target add x86_64-pc-windows-gnullvm aarch64-pc-windows-gnullvm
```

| Platform | Target triple | Command |
|---|---|---|
| Windows x86_64 | `x86_64-pc-windows-gnullvm` | `cargo build --release --target x86_64-pc-windows-gnullvm` |
| Windows ARM64  | `aarch64-pc-windows-gnullvm` | `cargo build --release --target aarch64-pc-windows-gnullvm` |

`.cargo/config.toml` sets the correct `linker` and `+crt-static` flag for each target.

```
target/x86_64-pc-windows-gnullvm/release/rsonanon.exe
target/aarch64-pc-windows-gnullvm/release/rsonanon.exe
```

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
# → target/x86_64-unknown-linux-musl/debian/rsonanon_0.2.0_amd64.deb

cross build --release --target aarch64-unknown-linux-musl
cargo deb --no-build --target aarch64-unknown-linux-musl
# → target/aarch64-unknown-linux-musl/debian/rsonanon_0.2.0_arm64.deb

# .rpm — Fedora
cross build --release --target x86_64-unknown-linux-musl
cargo generate-rpm --target x86_64-unknown-linux-musl
# → target/x86_64-unknown-linux-musl/generate-rpm/rsonanon-0.2.0-1.x86_64.rpm

cross build --release --target aarch64-unknown-linux-musl
cargo generate-rpm --target aarch64-unknown-linux-musl
# → target/aarch64-unknown-linux-musl/generate-rpm/rsonanon-0.2.0-1.aarch64.rpm
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
| `rsonanon-macos-x86_64` | macOS Intel |
| `rsonanon-macos-arm64` | macOS Apple Silicon |

> **macOS users:** binaries are not code-signed. After downloading, run
> `xattr -d com.apple.quarantine rsonanon-macos-arm64` (adjust filename as needed),
> or right-click → **Open** in Finder.

---

## Running tests

```bash
cargo build --release
bash tests/run_tests.sh
```

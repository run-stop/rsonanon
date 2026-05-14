use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::thread;
use serde_json::{Map, Value};

// ── RNG (SplitMix64) ─────────────────────────────────────────────────────────

struct Rng {
    state: u64,
}

impl Rng {
    fn new(seed: i64) -> Self {
        let s = seed as u64;
        Rng {
            state: if s == 0 { 0x9e3779b97f4a7c15 } else { s },
        }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }

    /// Returns a random integer in [0, n] inclusive.
    fn rand_n(&mut self, n: u64) -> u64 {
        if n == 0 {
            return 0;
        }
        self.next_u64() % (n + 1)
    }

    /// Returns a random float in [0.0, 1.0).
    fn rand_f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

// ── Constants ─────────────────────────────────────────────────────────────────

const FIRST_NAMES: &[&str] = &[
    "Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Avery", "Jamie", "Quinn", "Sam",
    "Maya", "Nora", "Lena", "Iris", "Victor", "Dylan",
];
const LAST_NAMES: &[&str] = &[
    "Smith", "Johnson", "Brown", "Miller", "Davis", "Wilson", "Taylor", "Anderson", "Clark",
    "Moore", "Walker", "Hall",
];
const CITIES: &[&str] = &[
    "Springfield", "Riverton", "Fairview", "Oakwood", "Franklin", "Georgetown", "Arlington",
    "Milton",
];
const STATES: &[&str] = &["CA", "NY", "TX", "WA", "OR", "IL", "MA", "CO"];
const COUNTRIES: &[&str] = &[
    "United States", "Netherlands", "Germany", "France", "Canada", "United Kingdom", "Australia",
];
const JOB_TITLES: &[&str] = &[
    "Engineer", "Manager", "Analyst", "Designer", "Consultant", "Director", "Coordinator",
    "Specialist",
];
const STATUS_VALUES: &[&str] = &["active", "pending", "inactive", "complete", "failed"];
const CURRENCIES: &[&str] = &["USD", "EUR", "GBP", "CHF", "CAD", "AUD"];

// ── Options ───────────────────────────────────────────────────────────────────

struct Options {
    input_path: String,
    output_path: String,
    pretty: bool,
    preserve_null: bool,
    seed: i64,
    seed_text: String,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            input_path: String::new(),
            output_path: String::new(),
            pretty: true,
            preserve_null: true,
            seed: 0,
            seed_text: String::new(),
        }
    }
}

// ── Helper functions ──────────────────────────────────────────────────────────

fn normalize_key(s: &str) -> String {
    s.chars()
        .filter_map(|c| {
            if c == '_' || c == '-' || c == ' ' {
                None
            } else {
                Some(c.to_ascii_lowercase())
            }
        })
        .collect()
}

fn contains_any(s: &str, parts: &[&str]) -> bool {
    parts.iter().any(|p| s.contains(p))
}

fn looks_like_email(s: &str) -> bool {
    match s.find('@') {
        Some(at) if at > 0 && at < s.len() - 1 => {
            if s.contains(' ') {
                return false;
            }
            let domain = &s[at + 1..];
            domain.find('.').map_or(false, |i| i > 0)
        }
        _ => false,
    }
}

fn looks_like_uuid(s: &str) -> bool {
    if s.len() != 36 {
        return false;
    }
    for (i, b) in s.bytes().enumerate() {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            if b != b'-' {
                return false;
            }
        } else if !b.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

fn looks_like_phone(s: &str) -> bool {
    if s.len() < 7 {
        return false;
    }
    let bytes = s.as_bytes();
    let mut i = 0;
    if bytes[i] == b'+' {
        i += 1;
    }
    if i >= bytes.len() || !bytes[i].is_ascii_digit() {
        return false;
    }
    i += 1;
    let mut digits = 0u32;
    while i < bytes.len() {
        match bytes[i] {
            b'0'..=b'9' => digits += 1,
            b' ' | b'.' | b'(' | b')' | b'-' => {}
            _ => return false,
        }
        i += 1;
    }
    digits >= 6
}

fn looks_like_url(s: &str) -> bool {
    s.starts_with("http://") || s.starts_with("https://")
}

fn looks_like_ipv4(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    parts
        .iter()
        .all(|p| !p.is_empty() && p.len() <= 3 && p.bytes().all(|b| b.is_ascii_digit()))
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

fn matches_date_ymd(s: &str) -> bool {
    let b = s.as_bytes();
    s.len() >= 10
        && b[4] == b'-'
        && b[7] == b'-'
        && all_digits(&s[0..4])
        && all_digits(&s[5..7])
        && all_digits(&s[8..10])
}

fn matches_date_slash_ymd(s: &str) -> bool {
    let b = s.as_bytes();
    s.len() == 10
        && b[4] == b'/'
        && b[7] == b'/'
        && all_digits(&s[0..4])
        && all_digits(&s[5..7])
        && all_digits(&s[8..10])
}

fn matches_date_slash_dmy(s: &str) -> bool {
    let b = s.as_bytes();
    s.len() == 10
        && b[2] == b'/'
        && b[5] == b'/'
        && all_digits(&s[0..2])
        && all_digits(&s[3..5])
        && all_digits(&s[6..10])
}

fn looks_like_date(s: &str) -> bool {
    matches_date_ymd(s) || matches_date_slash_dmy(s)
}

fn is_leap_year(y: u32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

/// Convert N days elapsed since 1990-01-01 into a (year, month, day) tuple.
fn days_to_date(mut days: u32) -> (u32, u32, u32) {
    let mut y = 1990u32;
    loop {
        let diy = if is_leap_year(y) { 366 } else { 365 };
        if days < diy {
            break;
        }
        days -= diy;
        y += 1;
    }
    let months: [u32; 12] = [
        31,
        if is_leap_year(y) { 29 } else { 28 },
        31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
    ];
    let mut m = 0usize;
    for &dm in &months {
        if days < dm {
            break;
        }
        days -= dm;
        m += 1;
    }
    (y, m as u32 + 1, days + 1)
}

fn pow10(n: usize) -> u64 {
    let mut r = 1u64;
    for _ in 0..n {
        r = r.saturating_mul(10);
    }
    r
}

fn count_digits(n: u64) -> usize {
    if n == 0 {
        return 1;
    }
    let mut x = n;
    let mut count = 0;
    while x > 0 {
        count += 1;
        x /= 10;
    }
    count
}

fn cache_key(path: &[String], value: &str) -> String {
    format!("{}={}", path.join("."), value)
}

fn seed_from_text(s: &str) -> i64 {
    // FNV-1a 64-bit – matches the Nim implementation for reproducible seeds.
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in s.as_bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h as i64
}

fn compute_seed(opts: &Options) -> i64 {
    if !opts.seed_text.is_empty() {
        return seed_from_text(&opts.seed_text);
    }
    if opts.seed != 0 {
        return opts.seed;
    }
    let d = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    (d.as_secs() as i64)
        .wrapping_mul(1_000_000_000)
        .wrapping_add(d.subsec_nanos() as i64)
}

fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

// ── Anonymizer ────────────────────────────────────────────────────────────────

struct Anonymizer {
    rng: Rng,
    preserve_null: bool,
    consistent: HashMap<String, String>,
}

impl Anonymizer {
    fn new(seed: i64, preserve_null: bool) -> Self {
        Anonymizer {
            rng: Rng::new(seed),
            preserve_null,
            consistent: HashMap::new(),
        }
    }

    fn pick_idx(&mut self, len: usize) -> usize {
        self.rng.rand_n((len - 1) as u64) as usize
    }

    fn fake_name(&mut self) -> String {
        let fi = self.pick_idx(FIRST_NAMES.len());
        let li = self.pick_idx(LAST_NAMES.len());
        format!("{} {}", FIRST_NAMES[fi], LAST_NAMES[li])
    }

    fn fake_email(&mut self) -> String {
        let fi = self.pick_idx(FIRST_NAMES.len());
        let li = self.pick_idx(LAST_NAMES.len());
        let num = 10 + self.rng.rand_n(89);
        format!(
            "{}.{}{}@example.test",
            FIRST_NAMES[fi].to_lowercase(),
            LAST_NAMES[li].to_lowercase(),
            num
        )
    }

    fn fake_phone(&mut self) -> String {
        let a = self.rng.rand_n(999);
        let b = self.rng.rand_n(9999);
        format!("+1-555-{:03}-{:04}", a, b)
    }

    fn fake_uuid(&mut self) -> String {
        let mut bytes = [0u8; 16];
        for b in bytes.iter_mut() {
            *b = self.rng.rand_n(255) as u8;
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        format!(
            "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }

    fn fake_street_address(&mut self) -> String {
        let suffixes = ["Street", "Avenue", "Road", "Lane", "Boulevard"];
        let si = self.pick_idx(suffixes.len());
        let num = 100 + self.rng.rand_n(9898);
        let li = self.pick_idx(LAST_NAMES.len());
        format!("{} {} {}", num, LAST_NAMES[li], suffixes[si])
    }

    fn fake_company(&mut self) -> String {
        const PREFIXES: &[&str] = &["Northstar", "Bluebird", "Oakridge", "Summit", "Evergreen", "Redwood"];
        const SUFFIXES: &[&str] = &["Systems", "Labs", "Group", "Holdings", "Partners"];
        let pi = self.pick_idx(PREFIXES.len());
        let si = self.pick_idx(SUFFIXES.len());
        format!("{} {}", PREFIXES[pi], SUFFIXES[si])
    }

    fn fake_company_slug(&mut self) -> String {
        self.fake_company().to_lowercase().replace(' ', "-")
    }

    fn fake_url(&mut self) -> String {
        const PATHS: &[&str] = &["profile", "orders", "account", "docs"];
        let slug = self.fake_company_slug();
        let pi = self.pick_idx(PATHS.len());
        format!("https://{}.example.test/{}", slug, PATHS[pi])
    }

    fn fake_iban(&mut self) -> String {
        let n1 = 10 + self.rng.rand_n(88);
        let n2 = self.rng.rand_n(9_999_999_999);
        format!("NL{:02}TEST{:010}", n1, n2)
    }

    fn fake_ipv4(&mut self) -> String {
        let a = self.rng.rand_n(255);
        let b = self.rng.rand_n(255);
        let c = self.rng.rand_n(255);
        format!("10.{}.{}.{}", a, b, c)
    }

    fn fake_same_shape_string(&mut self, s: &str) -> String {
        let mut result = String::with_capacity(s.len());
        for ch in s.chars() {
            let fake = match ch {
                'A'..='Z' => char::from(b'A' + self.rng.rand_n(25) as u8),
                'a'..='z' => char::from(b'a' + self.rng.rand_n(25) as u8),
                '0'..='9' => char::from(b'0' + self.rng.rand_n(9) as u8),
                other => other,
            };
            result.push(fake);
        }
        result
    }

    fn fake_date_like(&mut self, original: &str) -> String {
        let days = self.rng.rand_n(365 * 40) as u32;
        let (y, mo, d) = days_to_date(days);

        if original.len() >= 11 && matches_date_ymd(original) && original.as_bytes()[10] == b'T' {
            return format!("{:04}-{:02}-{:02}T00:00:00Z", y, mo, d);
        }
        if matches_date_slash_ymd(original) {
            return format!("{:04}/{:02}/{:02}", y, mo, d);
        }
        if matches_date_slash_dmy(original) {
            return format!("{:02}/{:02}/{:04}", d, mo, y);
        }
        if original.len() == 19 && matches_date_ymd(original) && original.as_bytes()[10] == b' ' {
            return format!("{:04}-{:02}-{:02} 00:00:00", y, mo, d);
        }
        format!("{:04}-{:02}-{:02}", y, mo, d)
    }

    fn fake_int_for_key(&mut self, key: &str, orig: i64) -> i64 {
        let abs_val = orig.unsigned_abs();
        // Cap at 18 digits to avoid u64 overflow in pow10.
        let digits = count_digits(abs_val).min(18);

        if key.contains("age") {
            return 18 + self.rng.rand_n(71) as i64;
        }
        if key.contains("year") {
            return 1970 + self.rng.rand_n(59) as i64;
        }
        if key.contains("month") {
            return 1 + self.rng.rand_n(11) as i64;
        }
        if key.contains("day") {
            return 1 + self.rng.rand_n(27) as i64;
        }
        if contains_any(key, &["count", "quantity", "qty", "items"]) {
            return self.rng.rand_n(999) as i64;
        }

        let min_val = if digits <= 1 { 0u64 } else { pow10(digits - 1) };
        let max_val = pow10(digits) - 1;
        let range = max_val - min_val;
        let fake = min_val as i64 + self.rng.rand_n(range) as i64;
        if orig < 0 { -fake } else { fake }
    }

    fn fake_float_for_key(&mut self, key: &str, orig: f64) -> f64 {
        if contains_any(key, &["lat", "latitude"]) {
            return -90.0 + self.rng.rand_f64() * 180.0;
        }
        if contains_any(key, &["lon", "lng", "longitude"]) {
            return -180.0 + self.rng.rand_f64() * 360.0;
        }
        let magnitude = if orig == 0.0 { 100.0 } else { orig.abs() };
        let min_val = magnitude * 0.25;
        let max_val = magnitude * 1.75;
        let result = min_val + self.rng.rand_f64() * (max_val - min_val);
        if orig < 0.0 { -result } else { result }
    }

    fn fake_string(&mut self, key: &str, value: &str, path: &[String]) -> String {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            return value.to_string();
        }

        let ck = cache_key(path, value);
        if let Some(cached) = self.consistent.get(&ck) {
            return cached.clone();
        }

        let nk = normalize_key(key);
        let nk = nk.as_str();

        let result = if looks_like_email(trimmed) || contains_any(nk, &["email", "mail"]) {
            self.fake_email()
        } else if looks_like_url(trimmed) || contains_any(nk, &["url", "uri", "website", "link"]) {
            self.fake_url()
        } else if looks_like_uuid(trimmed) || contains_any(nk, &["uuid", "guid"]) {
            self.fake_uuid()
        } else if contains_any(nk, &["postcode", "zipcode", "zip", "postal"]) {
            format!("{:05}", 10000 + self.rng.rand_n(89998))
        } else if looks_like_ipv4(trimmed) || contains_any(nk, &["ip", "ipaddress"]) {
            self.fake_ipv4()
        } else if contains_any(nk, &["date", "dob", "birth", "createdat", "updatedat", "timestamp"])
            || looks_like_date(trimmed)
        {
            self.fake_date_like(trimmed)
        } else if looks_like_phone(trimmed) || contains_any(nk, &["phone", "mobile", "telephone", "fax"]) {
            self.fake_phone()
        } else if contains_any(nk, &["firstname", "givenname"]) {
            let i = self.pick_idx(FIRST_NAMES.len());
            FIRST_NAMES[i].to_string()
        } else if contains_any(nk, &["lastname", "surname", "familyname"]) {
            let i = self.pick_idx(LAST_NAMES.len());
            LAST_NAMES[i].to_string()
        } else if contains_any(nk, &["fullname", "name", "contactperson", "customername", "username"]) {
            self.fake_name()
        } else if contains_any(nk, &["address", "street", "addr"]) {
            self.fake_street_address()
        } else if contains_any(nk, &["city", "town"]) {
            let i = self.pick_idx(CITIES.len());
            CITIES[i].to_string()
        } else if contains_any(nk, &["state", "province", "region"]) {
            let i = self.pick_idx(STATES.len());
            STATES[i].to_string()
        } else if contains_any(nk, &["country"]) {
            let i = self.pick_idx(COUNTRIES.len());
            COUNTRIES[i].to_string()
        } else if contains_any(nk, &["company", "organization", "organisation", "employer", "vendor"]) {
            self.fake_company()
        } else if contains_any(nk, &["currency"]) && trimmed.len() == 3 {
            let i = self.pick_idx(CURRENCIES.len());
            CURRENCIES[i].to_string()
        } else if contains_any(nk, &["status"]) {
            let i = self.pick_idx(STATUS_VALUES.len());
            STATUS_VALUES[i].to_string()
        } else if contains_any(nk, &["role", "title", "position"]) {
            let i = self.pick_idx(JOB_TITLES.len());
            JOB_TITLES[i].to_string()
        } else if contains_any(nk, &["iban"]) {
            self.fake_iban()
        } else {
            self.fake_same_shape_string(trimmed)
        };

        // Never return the original value unchanged.
        let result = if result == trimmed {
            self.fake_same_shape_string(trimmed)
        } else {
            result
        };

        self.consistent.insert(ck, result.clone());
        result
    }

    fn anonymize_at(&mut self, node: &Value, path: &[String], key: &str) -> Value {
        match node {
            Value::Object(map) => {
                let mut result = Map::new();
                for (k, v) in map {
                    let mut new_path = path.to_vec();
                    new_path.push(k.clone());
                    result.insert(k.clone(), self.anonymize_at(v, &new_path, k));
                }
                Value::Object(result)
            }
            Value::Array(arr) => {
                let mut result = Vec::with_capacity(arr.len());
                for (i, v) in arr.iter().enumerate() {
                    let mut new_path = path.to_vec();
                    new_path.push(i.to_string());
                    result.push(self.anonymize_at(v, &new_path, key));
                }
                Value::Array(result)
            }
            Value::String(s) => Value::String(self.fake_string(key, s, path)),
            Value::Number(n) => {
                let nk = normalize_key(key);
                if let Some(i) = n.as_i64() {
                    Value::Number(self.fake_int_for_key(&nk, i).into())
                } else if let Some(f) = n.as_f64() {
                    let faked = self.fake_float_for_key(&nk, f);
                    serde_json::Number::from_f64(faked)
                        .map(Value::Number)
                        .unwrap_or_else(|| node.clone())
                } else {
                    node.clone()
                }
            }
            Value::Bool(_) => Value::Bool(self.rng.rand_n(1) == 0),
            Value::Null => {
                if self.preserve_null {
                    Value::Null
                } else {
                    Value::String(self.fake_string(key, "Unknown", path))
                }
            }
        }
    }
}

// ── Parallel processing ───────────────────────────────────────────────────────

const PARALLEL_MIN_ELEMS: usize = 32;
const PARALLEL_MAX_WORKERS: usize = 8;

/// Indent every line of a pretty-printed JSON element by 2 spaces.
fn indent_element(s: &str) -> String {
    let newlines = s.bytes().filter(|&b| b == b'\n').count();
    let mut res = String::with_capacity(s.len() + newlines * 2 + 2);
    res.push_str("  ");
    for ch in s.chars() {
        res.push(ch);
        if ch == '\n' {
            res.push_str("  ");
        }
    }
    // Trim trailing spaces added after the final newline.
    while res.ends_with(' ') {
        res.pop();
    }
    res
}

fn anonymize_parallel(root: &[Value], opts: &Options, seed: i64) -> String {
    let n = root.len();
    let n_workers = PARALLEL_MAX_WORKERS.min(num_cpus()).min(n).max(1);
    let chunk_size = (n + n_workers - 1) / n_workers;

    struct ChunkSpec {
        json_str: String,
        seed: i64,
        preserve_null: bool,
        pretty: bool,
    }

    let chunks: Vec<ChunkSpec> = root
        .chunks(chunk_size)
        .enumerate()
        .map(|(idx, chunk)| {
            let w = (idx + 1) as i64;
            let worker_seed = seed ^ w ^ (w << 32);
            ChunkSpec {
                json_str: serde_json::to_string(&Value::Array(chunk.to_vec())).unwrap(),
                seed: worker_seed,
                preserve_null: opts.preserve_null,
                pretty: opts.pretty,
            }
        })
        .collect();

    let handles: Vec<_> = chunks
        .into_iter()
        .map(|spec| {
            thread::spawn(move || {
                let chunk_val: Value = serde_json::from_str(&spec.json_str).unwrap();
                let mut a = Anonymizer::new(spec.seed, spec.preserve_null);
                let anon = a.anonymize_at(&chunk_val, &[], "");
                if let Value::Array(elems) = anon {
                    if spec.pretty {
                        elems
                            .iter()
                            .map(|e| indent_element(&serde_json::to_string_pretty(e).unwrap()))
                            .collect::<Vec<_>>()
                            .join(",\n")
                    } else {
                        elems
                            .iter()
                            .map(|e| serde_json::to_string(e).unwrap())
                            .collect::<Vec<_>>()
                            .join(",")
                    }
                } else {
                    String::new()
                }
            })
        })
        .collect();

    let parts: Vec<String> = handles
        .into_iter()
        .filter_map(|h| h.join().ok())
        .filter(|s| !s.is_empty())
        .collect();

    if opts.pretty {
        format!("[\n{}\n]", parts.join(",\n"))
    } else {
        format!("[{}]", parts.join(","))
    }
}

// ── CLI ───────────────────────────────────────────────────────────────────────

fn usage() {
    eprintln!(
        r#"jsonanon - anonymize arbitrary JSON while preserving keys, structure, and JSON value types

Options:
  --in:<file>             Input JSON file. Defaults to stdin.
  --out:<file>            Output JSON file. Defaults to stdout.
  --pretty:on|off         Pretty-print output. Default: on.
  --seed:<integer>        Deterministic numeric seed. Default: current time.
  --seed-text:<text>      Deterministic text seed.
  --preserve-null:on|off  Keep null values as null. Default: on.
  --help                  Show help.

Examples:
  jsonanon --in:input.json --out:anon.json
  jsonanon --in:input.json --out:anon.json --seed-text:project-a
  cat input.json | jsonanon --pretty:off > anon.json
"#
    );
}

fn parse_bool_option(s: &str) -> Result<bool, String> {
    match s.to_lowercase().as_str() {
        "1" | "true" | "yes" | "y" | "on" => Ok(true),
        "0" | "false" | "no" | "n" | "off" => Ok(false),
        other => Err(format!("invalid boolean option: {}", other)),
    }
}

fn require_val<'a>(v: Option<&'a str>, name: &str) -> Result<&'a str, String> {
    v.ok_or_else(|| format!("option --{} requires a value", name))
}

fn parse_options() -> Result<Options, String> {
    let mut opts = Options::default();

    for arg in env::args().skip(1) {
        if arg == "--help" || arg == "-h" {
            usage();
            std::process::exit(0);
        }

        if !arg.starts_with('-') {
            return Err(format!("unexpected argument: {}", arg));
        }

        let rest = arg.trim_start_matches('-');

        let sep = rest.find(|c| c == ':' || c == '=');
        let (key, val) = match sep {
            Some(pos) => (&rest[..pos], Some(&rest[pos + 1..])),
            None => (rest, None),
        };

        match key {
            "in" | "i" => opts.input_path = require_val(val, "in")?.to_string(),
            "out" | "o" => opts.output_path = require_val(val, "out")?.to_string(),
            "pretty" => opts.pretty = parse_bool_option(require_val(val, "pretty")?)?,
            "preserve-null" => {
                opts.preserve_null = parse_bool_option(require_val(val, "preserve-null")?)?
            }
            "seed" => {
                let v = require_val(val, "seed")?;
                opts.seed = v
                    .parse::<i64>()
                    .map_err(|_| format!("invalid seed: {}", v))?;
            }
            "seed-text" => opts.seed_text = require_val(val, "seed-text")?.to_string(),
            "help" | "h" => {
                usage();
                std::process::exit(0);
            }
            other => return Err(format!("unknown option: {}", other)),
        }
    }

    Ok(opts)
}

fn read_input(path: &str) -> Result<String, String> {
    if path.is_empty() {
        let mut buf = String::new();
        io::stdin()
            .read_to_string(&mut buf)
            .map_err(|e| e.to_string())?;
        Ok(buf)
    } else {
        fs::read_to_string(path).map_err(|e| e.to_string())
    }
}

fn write_output(path: &str, content: &str) -> Result<(), String> {
    if path.is_empty() {
        println!("{}", content);
        io::stdout().flush().map_err(|e| e.to_string())?;
    } else {
        let mut f = fs::File::create(path).map_err(|e| e.to_string())?;
        writeln!(f, "{}", content).map_err(|e| e.to_string())?;
    }
    Ok(())
}

// ── Entry point ───────────────────────────────────────────────────────────────

fn main() {
    if let Err(e) = run() {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let opts = parse_options()?;
    let input = read_input(&opts.input_path)?;
    let root: Value = serde_json::from_str(&input).map_err(|e| e.to_string())?;
    let seed = compute_seed(&opts);

    let output = match &root {
        Value::Array(arr) if arr.len() >= PARALLEL_MIN_ELEMS && num_cpus() > 1 => {
            anonymize_parallel(arr, &opts, seed)
        }
        _ => {
            let mut a = Anonymizer::new(seed, opts.preserve_null);
            let anon = a.anonymize_at(&root, &[], "");
            if opts.pretty {
                serde_json::to_string_pretty(&anon).map_err(|e| e.to_string())?
            } else {
                serde_json::to_string(&anon).map_err(|e| e.to_string())?
            }
        }
    };

    write_output(&opts.output_path, &output)
}

---
name: asc-crash
description: Fetch and analyze crash reports from App Store Connect for the TeamClaw/AMUX iOS app. Use when the user asks about crashes, crash logs, diagnostics, or app stability.
---

# App Store Connect Crash Analysis

Fetch crash diagnostic data from App Store Connect API and analyze it against the codebase.

## Prerequisites

Credentials are in `.env` at the project root:
- `ASC_KEY_ID` — API Key ID
- `ASC_ISSUER_ID` — Issuer ID
- `ASC_KEY_FILE` — path to `.p8` private key
- `ASC_APP_ID` — App ID (TeamClaw = `6761966144`)

## Step 1: Load credentials and generate JWT

```bash
source .env
TOKEN=$(ruby -e '
require "base64"; require "json"; require "openssl"
key = OpenSSL::PKey::EC.new(File.read(ENV["ASC_KEY_FILE"]))
header = { alg: "ES256", kid: ENV["ASC_KEY_ID"], typ: "JWT" }
now = Time.now.to_i
payload = { iss: ENV["ASC_ISSUER_ID"], iat: now, exp: now + 1200, aud: "appstoreconnect-v1" }
segs = [header, payload].map { |h| Base64.urlsafe_encode64(JSON.generate(h), padding: false) }
input = segs.join(".")
sig = key.sign(OpenSSL::Digest::SHA256.new, input)
asn1 = OpenSSL::ASN1.decode(sig)
r = asn1.value[0].value.to_s(2).rjust(32, "\x00")[-32..]
s = asn1.value[1].value.to_s(2).rjust(32, "\x00")[-32..]
puts "#{input}.#{Base64.urlsafe_encode64(r + s, padding: false)}"
')
```

## Step 2: Fetch diagnostic signatures (crash groups)

```bash
curl -sS -g -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/apps/$ASC_APP_ID/diagnosticSignatures?filter%5BdiagnosticType%5D=DISK_WRITES,HANGS,CRASHES&limit=20"
```

This returns crash groups with:
- `attributes.diagnosticType` — CRASHES, HANGS, or DISK_WRITES
- `attributes.signature` — crash signature string
- `attributes.weight` — relative frequency (higher = more common)
- `relationships.logs` — link to detailed crash logs

## Step 3: Fetch crash logs for a specific signature

From each diagnostic signature, follow the `logs` relationship:

```bash
SIGNATURE_ID="<id from step 2>"
curl -sS -g -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/diagnosticSignatures/$SIGNATURE_ID/logs"
```

This returns individual crash instances with stack traces.

## Step 4: Analyze crashes against codebase

For each crash:
1. Parse the stack trace — look for frames in `AMUX`, `AMUXCore`, or `AMUXUI` modules
2. Map to source files using `grep` or `glob` on the symbol names
3. Identify the root cause and suggest fixes
4. Prioritize by `weight` (frequency)

## Step 5: Report findings

Present a summary table:
| Priority | Crash Signature | Count/Weight | Module | Likely Cause | Suggested Fix |
|----------|----------------|-------------|--------|-------------|--------------|

Then detail each crash with:
- Full stack trace (relevant frames)
- Source code context
- Root cause analysis
- Proposed fix

## Additional endpoints

### Performance metrics
```bash
curl -sS -g -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/apps/$ASC_APP_ID/perfPowerMetrics?filter%5BdeviceType%5D=iPhone&filter%5BmetricType%5D=HANG_RATE,LAUNCH_TIME,MEMORY,DISK"
```

### List builds (to correlate versions)
```bash
curl -sS -g -H "Authorization: Bearer $TOKEN" \
  "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=$ASC_APP_ID&sort=-uploadedDate&limit=5&fields%5Bbuilds%5D=version,uploadedDate,processingState"
```

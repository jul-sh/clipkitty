#!/bin/bash
# Sets up Mac Development provisioning profile for local builds.
# Uses App Store Connect API (via .age secrets) to:
#   1. Ensure an Apple Development certificate exists
#   2. Register this Mac as a development device
#   3. Create/download a Mac Development provisioning profile
#   4. Install the profile so xcodebuild can find it
#
# Usage:
#   ./distribution/setup-dev-provisioning.sh
#
# Requires: age secrets (NOTARY_KEY_ID, NOTARY_KEY_BASE64, NOTARY_ISSUER_ID)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
BUNDLE_ID="com.eviljuliette.clipkitty"
PROFILE_NAME="ClipKitty Mac Development"

# Check if a valid Mac Development profile is already installed
check_existing_profile() {
    for f in "$PROFILE_DIR"/*.provisionprofile; do
        [ -f "$f" ] || continue
        local plist
        plist=$(security cms -D -i "$f" 2>/dev/null) || continue
        local name
        name=$(echo "$plist" | plutil -extract Name raw - -o - 2>/dev/null) || continue
        if [ "$name" = "$PROFILE_NAME" ]; then
            # Check expiry using ruby for portable date parsing
            local expiry
            expiry=$(echo "$plist" | plutil -extract ExpirationDate raw - -o - 2>/dev/null) || continue
            if ruby -e 'require "time"; exit(Time.parse(ARGV[0]) > Time.now ? 0 : 1)' "$expiry" 2>/dev/null; then
                echo "Mac Development profile already installed and valid"
                return 0
            fi
        fi
    done
    return 1
}

if check_existing_profile; then
    exit 0
fi

echo "Setting up Mac Development provisioning profile..."

# Try installing from .age secret first (fast path, no API calls needed)
PROFILE_SECRET="$PROJECT_ROOT/secrets/MAC_DEV_PROVISIONING_PROFILE_BASE64.age"
if [ -f "$PROFILE_SECRET" ]; then
    echo "Installing provisioning profile from .age secret..."
    TMP_PROFILE=$(mktemp "${TMPDIR:-/tmp}/clipkitty-profile.XXXXXX")
    "$SCRIPT_DIR/read-secret.sh" MAC_DEV_PROVISIONING_PROFILE_BASE64 | base64 --decode > "$TMP_PROFILE"
    PLIST=$(security cms -D -i "$TMP_PROFILE" 2>/dev/null) || true
    PP_UUID=$(echo "$PLIST" | plutil -extract UUID raw - -o - 2>/dev/null) || true
    # Check if this device is in the profile's provisioned devices list
    MAC_UDID=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Provisioning UDID/{print $3}')
    DEVICE_IN_PROFILE=$(echo "$PLIST" | ruby -e '
        require "rexml/document"
        doc = REXML::Document.new(STDIN.read)
        devs = doc.elements.to_a("//dict/key[text()=\"ProvisionedDevices\"]/../array/string").map(&:text)
        puts "yes" if devs.include?(ARGV[0])
    ' "$MAC_UDID" 2>/dev/null) || true
    if [ -n "$PP_UUID" ] && [ "$DEVICE_IN_PROFILE" = "yes" ]; then
        mkdir -p "$PROFILE_DIR"
        cp "$TMP_PROFILE" "$PROFILE_DIR/$PP_UUID.provisionprofile"
        rm -f "$TMP_PROFILE"
        echo "Provisioning profile installed from .age: $PP_UUID"
        exit 0
    fi
    rm -f "$TMP_PROFILE"
    echo "Device not in .age profile, falling back to API..."
fi

# Decrypt API key
API_KEY_PATH="$PROJECT_ROOT/.make/keys/AuthKey.p8"
mkdir -p "$(dirname "$API_KEY_PATH")"
if [ ! -f "$API_KEY_PATH" ]; then
    "$SCRIPT_DIR/read-secret.sh" NOTARY_KEY_BASE64 | base64 --decode > "$API_KEY_PATH"
fi
KEY_ID=$("$SCRIPT_DIR/read-secret.sh" NOTARY_KEY_ID)
ISSUER_ID=$("$SCRIPT_DIR/read-secret.sh" NOTARY_ISSUER_ID)

# Generate JWT
generate_jwt() {
    ruby -e '
require "openssl"; require "base64"; require "json"
key = OpenSSL::PKey::EC.new(File.read(ARGV[0]))
header = Base64.urlsafe_encode64({"alg"=>"ES256","kid"=>ARGV[1],"typ"=>"JWT"}.to_json).delete("=")
now = Time.now.to_i
payload = Base64.urlsafe_encode64({"iss"=>ARGV[2],"iat"=>now,"exp"=>now+1200,"aud"=>"appstoreconnect-v1"}.to_json).delete("=")
sig_raw = key.sign("SHA256","#{header}.#{payload}")
asn = OpenSSL::ASN1.decode(sig_raw)
r = asn.value[0].value.to_s(2).rjust(32,"\0")
s = asn.value[1].value.to_s(2).rjust(32,"\0")
puts "#{header}.#{payload}.#{Base64.urlsafe_encode64(r+s).delete("=")}"
' "$API_KEY_PATH" "$KEY_ID" "$ISSUER_ID"
}

JWT=$(generate_jwt)
API="https://api.appstoreconnect.apple.com/v1"
AUTH="Authorization: Bearer $JWT"

# 1. Find or create Apple Development certificate
echo "Checking for Apple Development certificate..."
CERT_ID=$(curl -s -H "$AUTH" "$API/certificates?limit=200" | \
    ruby -rjson -e '
d = JSON.parse(STDIN.read)["data"]
cert = d.find { |c| c["attributes"]["certificateType"] == "DEVELOPMENT" }
puts cert["id"] if cert
' 2>/dev/null || true)

if [ -z "$CERT_ID" ]; then
    echo "Creating Apple Development certificate..."
    CSR_KEY=$(mktemp "${TMPDIR:-/tmp}/clipkitty-csr.XXXXXX.key")
    CSR_FILE=$(mktemp "${TMPDIR:-/tmp}/clipkitty-csr.XXXXXX.csr")
    trap 'rm -f "$CSR_KEY" "$CSR_FILE"' EXIT

    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$CSR_KEY" -out "$CSR_FILE" \
        -subj "/CN=Mac Development/O=ClipKitty/C=US" 2>/dev/null

    CSR_CONTENT=$(openssl req -in "$CSR_FILE" -outform DER 2>/dev/null | base64 | tr -d '\n')

    CERT_ID=$(curl -s -H "$AUTH" -H "Content-Type: application/json" \
        -X POST "$API/certificates" \
        -d '{"data":{"type":"certificates","attributes":{"certificateType":"DEVELOPMENT","csrContent":"'"$CSR_CONTENT"'"}}}' | \
        ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","id")')

    # Download cert content and create P12
    CERT_CONTENT=$(curl -s -H "$AUTH" "$API/certificates/$CERT_ID" | \
        ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","attributes","certificateContent")')

    P12_PATH=$(mktemp "${TMPDIR:-/tmp}/clipkitty-dev.XXXXXX.p12")
    echo "$CERT_CONTENT" | base64 --decode > "${P12_PATH}.cer"
    openssl x509 -inform DER -in "${P12_PATH}.cer" -out "${P12_PATH}.pem" 2>/dev/null
    openssl pkcs12 -export -out "$P12_PATH" -inkey "$CSR_KEY" -in "${P12_PATH}.pem" -passout pass:dev123 2>/dev/null

    # Store in .age secrets
    AGE_KEY=$(security find-generic-password -s keytap -a "AGE_SECRET_KEY_clipkitty" -w 2>/dev/null)
    AGE_PUB=$(echo "$AGE_KEY" | age-keygen -y 2>/dev/null)
    base64 < "$P12_PATH" | age -r "$AGE_PUB" -o "$PROJECT_ROOT/secrets/MAC_DEV_P12_BASE64.age"
    echo -n "dev123" | age -r "$AGE_PUB" -o "$PROJECT_ROOT/secrets/MAC_DEV_P12_PASSWORD.age"

    rm -f "${P12_PATH}.cer" "${P12_PATH}.pem" "$P12_PATH"
    echo "Created and stored Apple Development certificate: $CERT_ID"
fi

# 2. Register this Mac as a development device
echo "Registering this Mac..."
MAC_UDID=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Provisioning UDID/{print $3}')

# Refresh JWT (in case the previous operations took a while)
JWT=$(generate_jwt)
AUTH="Authorization: Bearer $JWT"

DEVICE_ID=$(curl -s -H "$AUTH" "$API/devices?limit=200" | \
    ruby -rjson -e '
d = JSON.parse(STDIN.read)["data"]
dev = d.find { |x| x["attributes"]["udid"] == ARGV[0] }
puts dev["id"] if dev
' "$MAC_UDID" 2>/dev/null || true)

if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(curl -s -H "$AUTH" -H "Content-Type: application/json" \
        -X POST "$API/devices" \
        -d '{"data":{"type":"devices","attributes":{"name":"ClipKitty Dev Mac","platform":"MAC_OS","udid":"'"$MAC_UDID"'"}}}' | \
        ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","id")')
    echo "Registered device: $DEVICE_ID"
else
    echo "Device already registered: $DEVICE_ID"
fi

# 3. Find the bundle ID resource
JWT=$(generate_jwt)
AUTH="Authorization: Bearer $JWT"

BUNDLE_ID_RESOURCE=$(curl -s -H "$AUTH" "$API/bundleIds?limit=200" | \
    ruby -rjson -e '
d = JSON.parse(STDIN.read)["data"]
b = d.find { |x| x["attributes"]["identifier"] == ARGV[0] }
puts b["id"] if b
' "$BUNDLE_ID" 2>/dev/null || true)

if [ -z "$BUNDLE_ID_RESOURCE" ]; then
    echo "Error: Bundle ID $BUNDLE_ID not found in App Store Connect" >&2
    exit 1
fi

# 4. Delete existing profile with same name (if expired/invalid)
JWT=$(generate_jwt)
AUTH="Authorization: Bearer $JWT"

ENCODED_NAME=$(ruby -e 'require "cgi"; puts CGI.escape(ARGV[0])' "$PROFILE_NAME")
EXISTING_PROFILE_ID=$(curl -s -H "$AUTH" "$API/profiles?filter[name]=$ENCODED_NAME&filter[profileType]=MAC_APP_DEVELOPMENT" | \
    ruby -rjson -e '
d = JSON.parse(STDIN.read)["data"]
puts d[0]["id"] if d && !d.empty?
' 2>/dev/null || true)

if [ -n "$EXISTING_PROFILE_ID" ]; then
    echo "Deleting existing profile..."
    curl -s -H "$AUTH" -X DELETE "$API/profiles/$EXISTING_PROFILE_ID" >/dev/null
fi

# 5. Create new provisioning profile
echo "Creating Mac Development provisioning profile..."
JWT=$(generate_jwt)
AUTH="Authorization: Bearer $JWT"

PROFILE_RESP=$(curl -s -H "$AUTH" -H "Content-Type: application/json" \
    -X POST "$API/profiles" \
    -d '{
    "data": {
        "type": "profiles",
        "attributes": {
            "name": "'"$PROFILE_NAME"'",
            "profileType": "MAC_APP_DEVELOPMENT"
        },
        "relationships": {
            "bundleId": { "data": { "type": "bundleIds", "id": "'"$BUNDLE_ID_RESOURCE"'" } },
            "certificates": { "data": [{ "type": "certificates", "id": "'"$CERT_ID"'" }] },
            "devices": { "data": [{ "type": "devices", "id": "'"$DEVICE_ID"'" }] }
        }
    }
}')

PROFILE_CONTENT=$(echo "$PROFILE_RESP" | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","attributes","profileContent")' 2>/dev/null)

if [ -z "$PROFILE_CONTENT" ]; then
    echo "Error creating profile:" >&2
    echo "$PROFILE_RESP" | ruby -rjson -e 'puts JSON.parse(STDIN.read).to_json' 2>/dev/null >&2
    exit 1
fi

# 6. Install the profile
echo "$PROFILE_CONTENT" | base64 --decode > /tmp/mac_dev.provisionprofile
PP_UUID=$(security cms -D -i /tmp/mac_dev.provisionprofile 2>/dev/null | plutil -extract UUID raw - -o - 2>/dev/null)

mkdir -p "$PROFILE_DIR"
cp /tmp/mac_dev.provisionprofile "$PROFILE_DIR/$PP_UUID.provisionprofile"
rm -f /tmp/mac_dev.provisionprofile

echo "Provisioning profile installed: $PP_UUID"

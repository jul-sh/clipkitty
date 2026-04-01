#!/bin/bash
# Sets up a Developer ID provisioning profile for CI distribution builds.
# Developer ID profiles don't require device registration, so they work on
# ephemeral CI runners. Required when the app uses CloudKit + App Sandbox
# entitlements with Developer ID signing.
#
# Usage:
#   ./distribution/setup-devid-provisioning.sh
#
# Requires: App Store Connect API key (NOTARY_KEY_ID, NOTARY_KEY_BASE64, NOTARY_ISSUER_ID)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
BUNDLE_ID="com.eviljuliette.clipkitty"
PROFILE_NAME="ClipKitty Developer ID"

# Check if a valid Developer ID profile is already installed
for f in "$PROFILE_DIR"/*.provisionprofile; do
    [ -f "$f" ] || continue
    plist=$(security cms -D -i "$f" 2>/dev/null) || continue
    name=$(echo "$plist" | plutil -extract Name raw - -o - 2>/dev/null) || continue
    if [ "$name" = "$PROFILE_NAME" ]; then
        expiry=$(echo "$plist" | plutil -extract ExpirationDate raw - -o - 2>/dev/null) || continue
        if ruby -e 'require "time"; exit(Time.parse(ARGV[0]) > Time.now ? 0 : 1)' "$expiry" 2>/dev/null; then
            echo "Developer ID profile already installed and valid"
            exit 0
        fi
    fi
done

echo "Setting up Developer ID provisioning profile..."

# Decrypt API key
API_KEY_PATH="$PROJECT_ROOT/.make/keys/AuthKey.p8"
mkdir -p "$(dirname "$API_KEY_PATH")"
if [ ! -f "$API_KEY_PATH" ]; then
    "$SCRIPT_DIR/read-secret.sh" NOTARY_KEY_BASE64 | base64 --decode > "$API_KEY_PATH"
fi
KEY_ID=$("$SCRIPT_DIR/read-secret.sh" NOTARY_KEY_ID)
ISSUER_ID=$("$SCRIPT_DIR/read-secret.sh" NOTARY_ISSUER_ID)

# Generate JWT for App Store Connect API
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

# 1. Find the Developer ID Application certificate
echo "Looking for Developer ID Application certificate..."
CERT_ID=$(curl -s -H "$AUTH" "$API/certificates?limit=200" | \
    ruby -rjson -e '
d = JSON.parse(STDIN.read)["data"]
# Match both DEVELOPER_ID_APPLICATION and DEVELOPER_ID_APPLICATION_G2
cert = d.find { |c| c["attributes"]["certificateType"].start_with?("DEVELOPER_ID_APPLICATION") }
if cert
    puts cert["id"]
else
    STDERR.puts "Available certificate types: #{d.map { |c| c["attributes"]["certificateType"] }.uniq.join(", ")}"
end
' 2>&1) || true

if [ -z "$CERT_ID" ]; then
    echo "Error: No Developer ID Application certificate found in App Store Connect" >&2
    echo "This certificate must be created in the Apple Developer portal" >&2
    exit 1
fi
echo "Found Developer ID certificate: $CERT_ID"

# 2. Find the bundle ID resource
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
echo "Found bundle ID: $BUNDLE_ID_RESOURCE"

# 3. Delete ALL existing profiles with the same name
JWT=$(generate_jwt)
AUTH="Authorization: Bearer $JWT"

echo "Checking for existing profiles named '$PROFILE_NAME'..."
EXISTING_PROFILE_IDS=$(curl -s -H "$AUTH" "$API/profiles?limit=200" | \
    ruby -rjson -e '
d = JSON.parse(STDIN.read)["data"]
d.select { |p| p["attributes"]["name"] == ARGV[0] }.each { |p| puts p["id"] }
' "$PROFILE_NAME" 2>/dev/null || true)

if [ -n "$EXISTING_PROFILE_IDS" ]; then
    echo "$EXISTING_PROFILE_IDS" | while read -r pid; do
        [ -n "$pid" ] || continue
        echo "Deleting existing profile: $pid"
        JWT_DEL=$(generate_jwt)
        curl -s -H "Authorization: Bearer $JWT_DEL" -X DELETE "$API/profiles/$pid" >/dev/null
    done
    echo "Deleted existing profiles"
else
    echo "No existing profiles found"
fi

# 4. Create Developer ID provisioning profile
# MAC_APP_DIRECT is the profile type for Developer ID distribution.
# Unlike MAC_APP_DEVELOPMENT, it does not require device registration.
echo "Creating Developer ID provisioning profile..."
JWT=$(generate_jwt)
AUTH="Authorization: Bearer $JWT"

PROFILE_RESP=$(curl -s -H "$AUTH" -H "Content-Type: application/json" \
    -X POST "$API/profiles" \
    -d '{
    "data": {
        "type": "profiles",
        "attributes": {
            "name": "'"$PROFILE_NAME"'",
            "profileType": "MAC_APP_DIRECT"
        },
        "relationships": {
            "bundleId": { "data": { "type": "bundleIds", "id": "'"$BUNDLE_ID_RESOURCE"'" } },
            "certificates": { "data": [{ "type": "certificates", "id": "'"$CERT_ID"'" }] }
        }
    }
}')

PROFILE_CONTENT=$(echo "$PROFILE_RESP" | ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","attributes","profileContent")' 2>/dev/null)

if [ -z "$PROFILE_CONTENT" ]; then
    echo "Error creating Developer ID profile:" >&2
    echo "$PROFILE_RESP" >&2
    exit 1
fi

# 5. Install the profile
echo "$PROFILE_CONTENT" | base64 --decode > /tmp/devid.provisionprofile
PP_UUID=$(security cms -D -i /tmp/devid.provisionprofile 2>/dev/null | plutil -extract UUID raw - -o - 2>/dev/null)

mkdir -p "$PROFILE_DIR"
cp /tmp/devid.provisionprofile "$PROFILE_DIR/$PP_UUID.provisionprofile"
rm -f /tmp/devid.provisionprofile

echo "Developer ID provisioning profile installed: $PP_UUID"

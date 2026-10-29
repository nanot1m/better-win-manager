#!/bin/bash
# Run only on a disposable macOS CI runner. Never enable shell tracing here.
set -euo pipefail
umask 077
: "${RUNNER_TEMP:?Set RUNNER_TEMP to an existing writable temporary directory}" "${APP_PATH:?}" "${ZIP_PATH:?}" "${APPLE_CERTIFICATE_P12_BASE64:?}" "${APPLE_CERTIFICATE_PASSWORD:?}"
: "${APPLE_SIGNING_IDENTITY:?}" "${APPLE_TEAM_ID:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_PRIVATE_KEY_BASE64:?}"
[[ "$APPLE_SIGNING_IDENTITY" == "Developer ID Application: "* ]] || { echo 'Expected a Developer ID Application identity'; exit 1; }

# Progress goes to the job log with a timestamp and the seconds since start, in collapsible groups. Nothing
# secret is ever printed: identities, team and key ids are public parts of the signature.
started=$(date +%s)
log() { printf '[%s +%4ds] %s\n' "$(date -u +%H:%M:%S)" "$(( $(date +%s) - started ))" "$*"; }
group() { echo "::group::$*"; log "$*"; }
endgroup() { echo "::endgroup::"; }
fail() { echo "::error::$*"; log "FAILED: $*"; exit 1; }

group "Prepare keychain"
secret_dir=$(mktemp -d "$RUNNER_TEMP/apple-release.XXXXXX")
keychain="$secret_dir/signing.keychain-db"
keychain_password=$(openssl rand -hex 32)
original_keychains=()
while IFS= read -r item; do
  item="${item#*\"}"; item="${item%\"*}"
  original_keychains+=("$item")
done < <(security list-keychains -d user)
cleanup() {
  log "Cleaning up: restoring keychain list, deleting the temporary keychain and secrets"
  security list-keychains -d user -s "${original_keychains[@]}" || true
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$secret_dir"
}
trap cleanup EXIT
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$secret_dir/certificate.p12"
printf '%s' "$ASC_PRIVATE_KEY_BASE64" | base64 --decode > "$secret_dir/AuthKey.p8"
log "Certificate: $(stat -f %z "$secret_dir/certificate.p12") bytes; API key: $(stat -f %z "$secret_dir/AuthKey.p8") bytes (key id $ASC_KEY_ID)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$secret_dir/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security -t cert -f pkcs12 -k "$keychain" >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
log "Identities in the keychain:"
security find-identity -v -p codesigning "$keychain" | sed 's/^/    /'
endgroup

group "Sign $APP_PATH"
log "Identity: $APPLE_SIGNING_IDENTITY; entitlements: Resources/BetterWM.entitlements; hardened runtime; secure timestamp"
# These bundles contain one executable and no nested frameworks or helpers.
codesign --force --timestamp --options runtime --entitlements Resources/BetterWM.entitlements --keychain "$keychain" --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --verbose=4 "$APP_PATH" 2> "$secret_dir/signature.txt"
grep -E '^(Identifier|Format|CodeDirectory|Signature size|Authority|Timestamp|TeamIdentifier|Runtime Version|flags)' "$secret_dir/signature.txt" | sed 's/^/    /'
grep -Fqx "TeamIdentifier=$APPLE_TEAM_ID" "$secret_dir/signature.txt" || fail "Signed with team $(grep '^TeamIdentifier=' "$secret_dir/signature.txt"), expected $APPLE_TEAM_ID"
grep -q 'flags=.*runtime' "$secret_dir/signature.txt" || fail "Hardened runtime flag is not set"
log "Entitlements as signed:"
codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | plutil -p - | sed 's/^/    /' || true
endgroup

group "Submit for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$secret_dir/submission.zip"
log "Submission zip: $(stat -f %z "$secret_dir/submission.zip") bytes"
xcrun notarytool store-credentials release-notary --keychain "$keychain" \
  --key "$secret_dir/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >/dev/null
# Submit without waiting, then poll: the job log shows the submission id at once and the status as it changes,
# instead of silence for however long Apple takes.
xcrun notarytool submit "$secret_dir/submission.zip" --keychain "$keychain" --keychain-profile release-notary \
  --output-format json > "$secret_dir/submit.json" || fail "notarytool submit failed: $(cat "$secret_dir/submit.json")"
submission_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$secret_dir/submit.json")
[[ -n "$submission_id" ]] || fail "No submission id in the notarytool answer: $(cat "$secret_dir/submit.json")"
log "Submitted: $submission_id (track it with: xcrun notarytool info $submission_id ...)"
endgroup

group "Wait for Apple"
deadline=$(( $(date +%s) + 55 * 60 ))
status="In Progress"
last=""
while :; do
  xcrun notarytool info "$submission_id" --keychain "$keychain" --keychain-profile release-notary --output-format json \
    > "$secret_dir/info.json" 2>/dev/null || true
  status=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("status", "unknown"))
except Exception: print("unknown")' "$secret_dir/info.json")
  [[ "$status" != "$last" ]] && { log "Status: $status"; last="$status"; }
  case "$status" in
    Accepted|Invalid|Rejected) break ;;
  esac
  if (( $(date +%s) >= deadline )); then
    log "Still '$status' after 55 minutes; giving up on this run. Apple may still finish; check the submission before re-running."
    fail "Notarization timed out (submission $submission_id)"
  fi
  sleep 30
done
endgroup

if [[ "$status" != Accepted ]]; then
  group "Apple's notarization log"
  xcrun notarytool log "$submission_id" --keychain "$keychain" --keychain-profile release-notary || true
  endgroup
  fail "Notarization did not complete successfully: $status (submission $submission_id)"
fi

group "Staple and verify"
# Stapling and validating both talk to Apple's CloudKit, which drops connections now and then.
retry() {
  for attempt in 1 2 3 4 5; do
    if "$@"; then return 0; fi
    (( attempt < 5 )) || fail "$1 $2 failed after $attempt attempts"
    log "$2 attempt $attempt failed; retrying in 20 s"
    sleep 20
  done
}
retry xcrun stapler staple "$APP_PATH"
retry xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
endgroup

group "Package"
mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(cd "$(dirname "$ZIP_PATH")" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")
log "$ZIP_PATH: $(stat -f %z "$ZIP_PATH") bytes, sha256 $(cut -d' ' -f1 "$ZIP_PATH.sha256")"
endgroup
log "Done"

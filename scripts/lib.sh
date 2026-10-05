# Helpers shared by build.sh and test.sh. Sourced, not executed; expects to run from the
# repository root.
#
# Signing (in order of preference):
#   THUMBD_SIGN_IDENTITY=<name or SHA-1>    a specific identity
#   THUMBD_TEAM_ID=<Team ID>                a valid certificate from that team: "Developer ID
#                                           Application" first, otherwise "Apple Development"
#                                           (keeps working when the certificate is renewed)
#   self-signed certificate "thumbd-signing"
#   ad-hoc ("-")
# The signing identifier is $THUMBD_SIGNING_ID (default carlosfontes.thumbd). With an Apple
# certificate, Santa sees it as the SigningID "<TeamID>:<identifier>".

# Library modules in dependency order.
MODULES=(Diagnostics HIDTransport HIDPP Gestures Actions Config)
SIGNING_ID="${THUMBD_SIGNING_ID:-carlosfontes.thumbd}"

# build_modules OUT OPT MODULE...: compiles each module into OUT as a static library plus its
# .swiftmodule, in the order given (dependencies first). OPT is -O or -Onone.
build_modules() {
  local out=$1 opt=$2 m
  shift 2
  for m in "$@"; do
    swiftc "$opt" -swift-version 5 -parse-as-library -emit-library -static -emit-module \
      -module-name "$m" -I "$out" -emit-module-path "$out/$m.swiftmodule" \
      -o "$out/lib$m.a" Sources/"$m"/*.swift
  done
}

# SHA-1 of the first valid Apple signing certificate whose OU (= Team ID) is $1.
# Prefers Developer ID Application: Santa ignores SigningID rules for binaries signed with
# development certificates (Apple Development).
identity_for_team() {
  local sha pem
  for sha in $(security find-identity -v -p codesigning |
               awk '/"Developer ID Application:/ { print $2 }';
               security find-identity -v -p codesigning |
               awk '/"Apple Development:/ { print $2 }'); do
    pem="$(security find-certificate -a -Z -p | awk -v h="$sha" '/^SHA-1 hash:/ { k = ($3 == h) } k' |
           sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p')"
    if openssl x509 -noout -subject -nameopt multiline <<<"$pem" 2>/dev/null |
       grep -qE "organizationalUnitName += $1\$"; then
      echo "$sha"
      return
    fi
  done
}

# Sets IDENTITY following the preference order above.
resolve_identity() {
  IDENTITY="${THUMBD_SIGN_IDENTITY:-}"
  if [[ -z "$IDENTITY" && -n "${THUMBD_TEAM_ID:-}" ]]; then
    IDENTITY="$(identity_for_team "$THUMBD_TEAM_ID")"
    [[ -n "$IDENTITY" ]] || { echo "No valid certificate for team $THUMBD_TEAM_ID" >&2; exit 1; }
  fi
  if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"thumbd-signing"'; then
    IDENTITY="thumbd-signing"
  fi
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "⚠️  Ad-hoc signature: the designated requirement will be the cdhash, which changes on every" >&2
    echo "   build; macOS will stop recognizing granted permissions after rebuilding (see README)." >&2
  fi
}

#!/usr/bin/env bash
# Smoke test a deployed copy of the site. Run it right after go-live.
#
#   tools/smoke-test.sh [URL] [--dev] [--www]
#
#   URL      site to test (default https://kerim-kilic.com)
#   --dev    expect the dev build: noindex, Disallow, and Cloudflare in front
#   --www    also check that www.<host> redirects to <host> (prod only)
#
# Extra request headers (for example a Cloudflare Access service token when testing dev) can be passed
# newline-separated in SMOKE_HEADERS. Exits non-zero if any check fails.
set -uo pipefail

url="${1:-https://kerim-kilic.com}"
[[ "$url" == --* ]] && url="https://kerim-kilic.com" || shift || true
mode=prod
check_www=0
for arg in "$@"; do
  case "$arg" in
    --dev) mode=dev ;;
    --www) check_www=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
url="${url%/}"
scheme="${url%%://*}"
host="${url#*://}"
host="${host%%/*}"

curl_opts=()
while IFS= read -r header; do [[ -n "$header" ]] && curl_opts+=(-H "$header"); done <<<"${SMOKE_HEADERS:-}"

pass=0
fail=0
ok()   { echo "  PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
info() { echo "  info  $1"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

status()  { curl -s -o /dev/null -w '%{http_code}' "${curl_opts[@]+"${curl_opts[@]}"}" "$1"; }
headers() { curl -s -D - -o /dev/null "${curl_opts[@]+"${curl_opts[@]}"}" "$1" | tr -d '\r'; }
body()    { curl -s "${curl_opts[@]+"${curl_opts[@]}"}" "$1"; }
hdr()     { grep -i "^$2:" <<<"$1" | head -1 | cut -d: -f2- | sed 's/^ *//'; }

echo "Smoke test: $url ($mode)"

echo; echo "Pages"
for path in / /about/ /articles/ /portfolio/ /contact/ /sitemap.xml /robots.txt /favicon.ico /favicon.svg /apple-touch-icon.png; do
  code=$(status "$url$path")
  expect "$path returns 200 (got $code)" '[[ "$code" == 200 ]]'
done

code=$(status "$url/this-page-does-not-exist/")
expect "a missing page returns a real 404 (got $code)" '[[ "$code" == 404 ]]'
expect "the 404 page is the site's own" 'body "$url/this-page-does-not-exist/" | grep -qi "page not found"'

echo; echo "Environment (catches a dev build on prod, or the reverse)"
html=$(body "$url/" | tr -d "\"'")
canonical=$(sed -nE 's/.*rel=canonical href=([^ >]+).*/\1/p' <<<"$html" | head -1)
expect "canonical URL points at this host ($canonical)" '[[ "$canonical" == "$url/" ]]'
ogimage=$(sed -nE 's/.*property=og:image content=([^ >]+).*/\1/p' <<<"$html" | head -1)
expect "share image URL is absolute and on this host" '[[ "$ogimage" == "$url/"* ]]'
if [[ -n "$ogimage" ]]; then
  ogtype=$(hdr "$(headers "$ogimage")" content-type)
  expect "share image loads as an image ($ogtype)" '[[ "$ogtype" == image/* ]]'
fi
robots=$(body "$url/robots.txt")
if [[ "$mode" == dev ]]; then
  expect "robots.txt disallows everything" 'grep -qx "Disallow: /" <<<"$robots"'
  expect "pages carry noindex" 'grep -qiE "name=robots content=[^>]*noindex" <<<"$html"'
else
  expect "robots.txt lists the sitemap" 'grep -q "^Sitemap: $url/sitemap.xml" <<<"$robots"'
  expect "robots.txt does not block the site" '! grep -qx "Disallow: /" <<<"$robots"'
  expect "pages are not marked noindex" '! grep -qiE "name=robots content=[^>]*noindex" <<<"$html"'
fi

echo; echo "Cloudflare rewrites"
contact=$(body "$url/contact/")
expect "contact page has a mailto link" 'grep -q "mailto:" <<<"$contact"'
expect "email address was not obfuscated by Cloudflare" '! grep -q "email-protection" <<<"$contact"'

if [[ "$scheme" == https ]]; then
  echo; echo "HTTPS, headers and caching"
  resp=$(headers "$url/")
  expect "Strict-Transport-Security is set" '[[ -n "$(hdr "$resp" strict-transport-security)" ]]'
  expect "X-Content-Type-Options is nosniff" '[[ "$(hdr "$resp" x-content-type-options)" == *nosniff* ]]'
  expect "Referrer-Policy is set" '[[ -n "$(hdr "$resp" referrer-policy)" ]]'
  expect "HTML is revalidated by browsers ($(hdr "$resp" cache-control))" '[[ "$(hdr "$resp" cache-control)" == *must-revalidate* ]]'

  css=$(sed -nE 's/.*href=(\/css\/[^ >]+\.css).*/\1/p' <<<"$html" | head -1)
  if [[ -n "$css" ]]; then
    cssresp=$(headers "$url$css")
    expect "fingerprinted CSS is cached for a year ($(hdr "$cssresp" cache-control))" '[[ "$(hdr "$cssresp" cache-control)" == *immutable* ]]'
  fi
  fontresp=$(headers "$url/fonts/inter.woff2")
  expect "fonts are served as woff2 ($(hdr "$fontresp" content-type))" '[[ "$(hdr "$fontresp" content-type)" == *woff2* ]]'

  location=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://$host/")
  expect "http:// redirects to https ($location)" '[[ "$location" == 30[18]\ https://* ]]'

  if [[ "$check_www" == 1 && "$mode" == prod ]]; then
    wwwloc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "https://www.$host/about/")
    expect "www redirects to the apex ($wwwloc)" '[[ "$wwwloc" == "301 $url/about/" ]]'
  fi

  echo; echo "Certificate and edge"
  certinfo=$(echo | openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null | openssl x509 -noout -issuer -enddate -ext subjectAltName 2>/dev/null)
  issuer=$(grep -i '^issuer' <<<"$certinfo" | head -1)
  info "$issuer"
  if [[ "$mode" == prod ]]; then
    expect "certificate is from Amazon (ACM)" 'grep -qi amazon <<<"$issuer"'
    expect "certificate covers $host" 'grep -q "DNS:$host" <<<"$certinfo"'
    [[ "$check_www" == 1 ]] && expect "certificate covers www.$host" 'grep -q "DNS:www.$host" <<<"$certinfo"'
    expect "certificate is valid for at least 14 more days" 'echo | openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null | openssl x509 -noout -checkend $((14 * 86400)) >/dev/null'
    expect "served by CloudFront" '[[ -n "$(hdr "$resp" x-amz-cf-id)" ]]'
    expect "not proxied by Cloudflare (prod is DNS-only)" '[[ -z "$(hdr "$resp" cf-ray)" ]]'
  else
    expect "served through Cloudflare (dev sits behind Access)" '[[ -n "$(hdr "$resp" cf-ray)" ]]'
  fi
else
  info "http:// URL: skipping TLS, header and cache checks"
fi

echo; echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]

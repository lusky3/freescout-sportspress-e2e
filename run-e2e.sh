#!/usr/bin/env bash
# ==========================================================================
# run-e2e.sh -- bring up the FreeScout <-> SportsPress Waitlist Status
# end-to-end test stack, fully configured, with as little manual browser
# interaction as we could get away with.
#
# See README.md for what this wires together. Safe to re-run: FreeScout
# core is cloned only if missing, migrations are idempotent, and the admin
# user / module config steps are skipped if already done.
# ==========================================================================
set -euo pipefail

cd "$(dirname "$0")"

COMPOSE="docker compose"
FREESCOUT_URL="http://localhost:8093"
SPORTSPRESS_URL="http://localhost:8092"
ADMIN_EMAIL="admin@example.test"
ADMIN_PASSWORD="AdminPass123!"
FIXTURE_EMAIL="fixture-waitlist@example.test"
SECRETS_FILE=".e2e-secrets"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

# --------------------------------------------------------------------
# 1. FreeScout core: clone fresh if missing, write a docker-appropriate .env
# --------------------------------------------------------------------
if [ ! -d freescout-core ] || [ ! -f freescout-core/artisan ]; then
    log "Cloning FreeScout core into ./freescout-core (gitignored, not shared with freescout-splm-waitlist's own clone)"
    rm -rf freescout-core
    git clone --depth 1 https://github.com/freescout-help-desk/freescout.git freescout-core
fi

if [ ! -f freescout-core/.env ]; then
    log "Writing freescout-core/.env"
    cp freescout-core/.env.example freescout-core/.env
    sed -i 's/^DB_HOST=.*/DB_HOST=freescout-db/' freescout-core/.env
    sed -i 's/^DB_DATABASE=.*/DB_DATABASE=freescout/' freescout-core/.env
    sed -i 's/^DB_USERNAME=.*/DB_USERNAME=freescout/' freescout-core/.env
    sed -i 's/^DB_PASSWORD=.*/DB_PASSWORD=freescout/' freescout-core/.env
    sed -i "s#^APP_URL=.*#APP_URL=${FREESCOUT_URL}#" freescout-core/.env
    grep -q '^APP_TRUSTED_HOSTS=' freescout-core/.env || echo 'APP_TRUSTED_HOSTS=localhost,freescout-web' >> freescout-core/.env
fi

# --------------------------------------------------------------------
# 2. Build + start everything
# --------------------------------------------------------------------
log "docker compose up -d --build"
$COMPOSE up -d --build

# --------------------------------------------------------------------
# 3. Wait for sportspress-test's own healthcheck (installs WP/SportsPress/
#    WooCommerce and enables league_waitlist via its own setup-test-data.sh)
# --------------------------------------------------------------------
log "Waiting for sportspress-test to report healthy..."
for i in $(seq 1 40); do
    if curl -sf "${SPORTSPRESS_URL}/wp-json/test/v1/health" | grep -q '"status":"ready"'; then
        echo "sportspress-test is ready."
        break
    fi
    if [ "$i" -eq 40 ]; then
        echo "sportspress-test did not become healthy in time." >&2
        exit 1
    fi
    sleep 6
done

# --------------------------------------------------------------------
# 4. Waitlist fixture: a queued entry for fixture-waitlist@example.test
# --------------------------------------------------------------------
log "Creating waitlist fixture data..."
$COMPOSE exec sportspress-test bash /usr/local/bin/fixtures-waitlist.sh

# --------------------------------------------------------------------
# 5. Shared HMAC secret
# --------------------------------------------------------------------
if [ -f "$SECRETS_FILE" ]; then
    log "Reusing existing shared secret from $SECRETS_FILE"
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
else
    log "Generating a new shared HMAC secret"
    SECRET=$(openssl rand -hex 32)
    printf 'SECRET=%s\n' "$SECRET" > "$SECRETS_FILE"
    chmod 600 "$SECRETS_FILE"
fi

log "Setting splm_freescout_secret option on the WordPress side"
$COMPOSE exec sportspress-test wp option update splm_freescout_secret "$SECRET" --allow-root >/dev/null

# --------------------------------------------------------------------
# 6. FreeScout install, entirely via artisan -- no browser wizard
# --------------------------------------------------------------------
log "Generating FreeScout APP_KEY (if not already set)"
# key:generate --force always overwrites, even if a key is already set --
# fine on a brand-new install, but re-running this script against an
# already-configured stack would needlessly rotate the key. Guard it.
if grep -q '^APP_KEY=base64:' freescout-core/.env; then
    echo "APP_KEY already set, skipping."
else
    $COMPOSE exec freescout-app php artisan key:generate --force
fi

log "Running FreeScout migrations"
$COMPOSE exec freescout-app php artisan migrate --force

log "Creating FreeScout admin user (skipped if it already exists)"
# NOTE #1: whatever we pipe into `artisan tinker` gets echoed back by psysh
# before its result, so any sentinel string embedded in the *source* line
# (e.g. a literal 'FOUND_USER' inside the ternary) will match a grep for
# that same string regardless of which branch actually ran. Counting rows
# is safe because the count only appears in tinker's *output*, never in
# the echoed input line.
# NOTE #2: `echo` without a trailing "\n" leaves psysh's cursor mid-line,
# and it then appends a visual "return" glyph (U+23CE) to the same line
# before its next prompt -- which breaks a `^[0-9]+$` match. Appending
# "\n" ourselves avoids that.
USER_COUNT=$($COMPOSE exec -T freescout-app php artisan tinker <<'PHP' 2>/dev/null | grep -E '^[0-9]+$' | tail -1
echo \App\User::where('email', 'admin@example.test')->count() . "\n";
PHP
)
USER_COUNT="${USER_COUNT:-0}"
if [ "$USER_COUNT" -eq 0 ]; then
    $COMPOSE exec freescout-app php artisan freescout:create-user \
        --role=admin --firstName=Admin --lastName=User \
        --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD" -n
else
    echo "Admin user already exists, skipping."
fi

log "Marking FreeScout as installed (storage/.installed) and clearing cache"
$COMPOSE exec freescout-app touch storage/.installed
$COMPOSE exec freescout-app php artisan freescout:clear-cache

# --------------------------------------------------------------------
# 7. Enable + configure the SplmWaitlist module
# --------------------------------------------------------------------
log "Enabling the SplmWaitlist module and configuring its two settings"
# NOTE: `php artisan module:enable` in this FreeScout fork keys modules by
# the "name" field in module.json ("SportsPress Waitlist Status"), not the
# folder name or alias -- confirmed by reading
# overrides/nwidart/laravel-modules/src/Repository.php's scan(). More
# reliably, FreeScout's own activation source of truth is the `modules` DB
# table (App\Module::isActive()/setActive()), so we set that directly.
$COMPOSE exec -T freescout-app php artisan tinker <<PHP
\App\Module::setActive('splmwaitlist', true);
\Option::set('splmwaitlist.wp_base_url', 'http://sportspress-test');
\Option::set('splmwaitlist.shared_secret', '$SECRET');
PHP

$COMPOSE exec freescout-app php artisan freescout:clear-cache

# --------------------------------------------------------------------
# 8. Prove the whole chain works, without a browser: hand-computed HMAC
#    request from inside freescout-app straight to the WP endpoint.
# --------------------------------------------------------------------
log "Verifying end-to-end: HMAC-signed request from freescout-app to sportspress-test"
cat > /tmp/splm-e2e-hmac-check.php <<PHP
<?php
\$secret = '$SECRET';
\$body = json_encode(['email' => '$FIXTURE_EMAIL']);
\$timestamp = (string) time();
\$signature = hash_hmac('sha256', \$timestamp . '.' . \$body, \$secret);

\$ch = curl_init('http://sportspress-test/wp-json/splm/v1/waitlist/customer-status');
curl_setopt_array(\$ch, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => \$body,
    CURLOPT_HTTPHEADER => [
        'Content-Type: application/json',
        'X-SPLM-Timestamp: ' . \$timestamp,
        'X-SPLM-Signature: ' . \$signature,
    ],
    CURLOPT_RETURNTRANSFER => true,
]);
\$response = curl_exec(\$ch);
\$status = curl_getinfo(\$ch, CURLINFO_HTTP_CODE);
curl_close(\$ch);

echo "HTTP STATUS: \$status\n";
echo "BODY: \$response\n";

// This is the actual pass/fail gate, not just a print for a human to
// eyeball -- a non-2xx status, or a response missing the fixture's
// expected 'queued' entry, means the WP<->FreeScout chain is broken, and
// this script (and CI, which runs it as its own check) needs to fail
// loudly rather than report a misleadingly clean exit.
\$data = json_decode((string) \$response, true);
\$ok = \$status === 200
    && is_array(\$data)
    && isset(\$data['entries']) && is_array(\$data['entries'])
    && count(\$data['entries']) > 0
    && \$data['entries'][0]['status'] === 'queued';

if (!\$ok) {
    fwrite(STDERR, "End-to-end verification FAILED: expected HTTP 200 with a queued entry.\n");
    exit(1);
}

echo "End-to-end verification passed: WordPress returned a queued waitlist entry to FreeScout.\n";
PHP
docker cp /tmp/splm-e2e-hmac-check.php "$($COMPOSE ps -q freescout-app)":/tmp/splm-e2e-hmac-check.php
$COMPOSE exec freescout-app php /tmp/splm-e2e-hmac-check.php

# --------------------------------------------------------------------
# 9. Summary
# --------------------------------------------------------------------
log "Done"
cat <<SUMMARY

FreeScout:    ${FREESCOUT_URL}
Admin login:  ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}

To see it in the UI:
  1. Log in at ${FREESCOUT_URL}/login
  2. Create (or open) a conversation with customer email:
       ${FIXTURE_EMAIL}
  3. Confirm the "SportsPress Waitlist" panel in the sidebar shows
     something like "On waitlist (S2027)".

SportsPress admin: ${SPORTSPRESS_URL}/wp-admin/ (auto-login enabled by the
sandbox image).

Shared secret is stored in ${SECRETS_FILE} (gitignored) for reuse across runs.

Tear down with: docker compose down -v
SUMMARY

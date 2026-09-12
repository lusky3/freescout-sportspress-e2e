# freescout-sportspress-e2e

A combined Docker Compose environment for exercising the FreeScout
**SportsPress Waitlist Status** module end-to-end: a real WordPress +
SportsPress + WooCommerce site, with a real queued waitlist entry, talking
over HTTP to a real FreeScout instance running the module, showing the
waitlist status in FreeScout's conversation sidebar.

This repo has no other purpose, so `docker-compose.yml` lives at the repo
root rather than under a `docker/` subdirectory.

## What it wires together

- **`sportspress-test`** -- reuses [`sportspress-sandbox`](../sportspress-sandbox)'s
  own `Dockerfile` and plugin-mount layout unchanged (as its build context),
  on host port `8092` instead of that repo's own `8082`, so the two stacks
  never collide if both happen to be running. Its own healthcheck and
  `setup-test-data.sh` (which installs WordPress/SportsPress/WooCommerce and
  enables the `league_waitlist` module) run exactly as they do there --
  nothing about that machinery is duplicated here.
- **`freescout-db` / `freescout-app` / `freescout-web`** -- a FreeScout
  instance modeled on [`freescout-splm-waitlist/docker/`](../freescout-splm-waitlist/docker)'s
  own dev harness pattern (same nginx config, same PHP Dockerfile), but with
  FreeScout core cloned fresh into `./freescout-core/` (gitignored, **not**
  shared with that repo's own separate clone), and the module's actual
  source bind-mounted straight from `../freescout-splm-waitlist` -- so this
  is the real code under test, not a copy. Web UI on host port `8093`,
  MySQL on host port `33064`.
- **`e2e-net`** -- one shared bridge network joining all of the above, so
  FreeScout can reach WordPress at `http://sportspress-test` (that's the
  URL configured into the module's settings).

### On the `sportspress-league-manager` mount path

The customer-status REST route this whole stack exists to exercise
(`POST /wp-json/splm/v1/waitlist/customer-status`) is not yet on
`SportsPress-Admin-Tools`'s `main` branch as of this writing -- only on the
`worktree-freescout-waitlist-integration` branch/worktree. `docker-compose.yml`
mounts `${LEAGUE_MANAGER_PATH:-../SportsPress-Admin-Tools/sportspress-league-manager}`,
and `.env` currently pins `LEAGUE_MANAGER_PATH` to that worktree's checkout.
Once the feature merges to `main`, delete that line from `.env` (or point it
back at the plain sibling path) and the default takes over.

### On the module's own `docker/` directory

`../freescout-splm-waitlist` is bind-mounted whole into
`Modules/SplmWaitlist`, which means that repo's own `docker/` (a completely
separate dev harness -- its own compose file, nginx config, PHP Dockerfile)
would otherwise show up, unused but present, at
`Modules/SplmWaitlist/docker/` inside the `freescout-app` container. This
is **not** a bind-mount recursion loop -- that failure mode is mounting a
directory into a path inside itself on the *same* host tree, and these are
two independent sibling repos, so nothing actually loops. It's excluded
anyway (an empty named volume shadows it, the same trick
`freescout-splm-waitlist/docker/docker-compose.yml` uses for the identical
situation in its own harness), purely so this container has no reason to
ever read or execute that other harness's files.

## Prerequisites

- Docker with Compose v2 (`docker compose ...`, not `docker-compose`).
- Network access to clone FreeScout core from GitHub on first run.

## Usage

```sh
./run-e2e.sh
```

This single script:

1. Clones FreeScout core into `./freescout-core/` (skipped if already
   present) and writes its `.env` for the Docker network.
2. `docker compose up -d --build`.
3. Waits for `sportspress-test`'s healthcheck.
4. Runs `sportspress-sandbox`'s own `fixtures-waitlist.sh` inside that
   container, creating a queued waitlist entry for
   `fixture-waitlist@example.test`.
5. Generates a random shared HMAC secret (or reuses the one from a
   previous run, stored in the gitignored `.e2e-secrets`) and sets it as
   `splm_freescout_secret` on the WordPress side via `wp option update`.
6. Installs FreeScout **entirely via `artisan`, no browser wizard**: runs
   migrations, creates an admin user (`freescout:create-user`), and marks
   the install complete by touching `storage/.installed` (the marker
   FreeScout's own `canInstall` middleware override checks first).
7. Enables the module and configures its two settings
   (`splmwaitlist.wp_base_url`, `splmwaitlist.shared_secret`) via
   `App\Module::setActive()` and `\Option::set()` through `artisan tinker`.
8. Proves the whole chain works with a hand-computed HMAC-signed `curl`
   request, sent from *inside* the `freescout-app` container straight to
   the WP endpoint -- the same request the module's own `WaitlistClient`
   makes, with the same signature scheme
   (`hash_hmac('sha256', "$timestamp.$body", $secret)` in the
   `X-SPLM-Timestamp` / `X-SPLM-Signature` headers). Expect:

   ```json
   {"email":"fixture-waitlist@example.test","entries":[{"season":"S2027","status":"queued","offered_at":null,"expires_at":null}]}
   ```

9. Prints the FreeScout URL, the admin login, and what to click next.

Safe to re-run: every step is guarded (existing FreeScout clone, existing
`APP_KEY`, existing admin user, existing secret file are all reused/skipped
rather than redone).

## Everything is automated -- no manual step required

Every step above, including full FreeScout installation and module
configuration, runs via CLI (`artisan`, `wp`, `tinker`). No browser
interaction is needed to get the stack into a working state. FreeScout's
own web installer wizard is bypassed entirely by running its migrations and
admin-user creation directly and then setting the `storage/.installed`
marker its `canInstall` middleware override checks for.

The one thing that genuinely does need a human (or a browser-automation
tool) is the actual **verification in the sidebar UI** -- confirming the
"SportsPress Waitlist" panel renders and shows "On waitlist (S2027)" for a
conversation with `fixture-waitlist@example.test` -- since that's a visual
React/Blade component, not something `curl` can meaningfully assert on. The
`run-e2e.sh` HMAC test proves the underlying data flow works; opening
`http://localhost:8093/login`, logging in, and starting a conversation with
that customer email is how you'd see it rendered.

## Tear down

```sh
docker compose down -v
```

`./freescout-core/` is a bind mount, not a volume, so `down -v` won't clean
it up and some files in it end up owned by the container's `www-data` user.
To fully reset it:

```sh
docker run --rm -v "$(pwd)/freescout-core:/target" alpine sh -c 'rm -rf /target/* /target/.[!.]*'
rmdir freescout-core
rm -f .e2e-secrets
```

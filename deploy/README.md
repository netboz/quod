# Infrastructure jobs

Runbook for the non-quod jobs under `deploy/`. Run everything from the repo root with
`NOMAD_ADDR=http://192.168.1.10:4646`. The `quod`, `quod-finality-candidate*` and
`quod-cloud` jobs have their own procedure in `quod.nomad`; nothing here touches them.

Nomad has no ACLs: anyone on the LAN who can reach the API can read job specs and
Nomad variables. Secrets are kept out of the repository, not out of the cluster.

## Forgejo

| | |
|---|---|
| Job | `deploy/forgejo.nomad` |
| Web | http://forgejo.service.consul (system Traefik :80, LAN only, plain HTTP) |
| SSH | `ssh://git@forgejo.service.consul:2222/<owner>/<repo>.git` |
| Data | Ceph RBD CSI volume `forgejo-data` (20 GiB, NAS) at `/data` |
| Database | SQLite, `/data/gitea/forgejo.db`, WAL |
| Version | `forgejo_version` variable, pinned to an exact tag |

### First deploy

1. Create the volume once. The Ceph key of `client.nomad-csi` lives in the homelab
   repository (`~/src/qengho.org/nomad-jobs/volumes/*.hcl`) and on the Ceph cluster;
   it is substituted from the environment so it never enters this repository:

   ```sh
   export CEPH_CSI_USER_KEY=$(sed -n 's/^ *userKey *= *"\(.*\)"/\1/p' \
     ~/src/qengho.org/nomad-jobs/volumes/vaultwarden-data.hcl)
   perl -pe 's/__CEPH_CSI_USER_KEY__/$ENV{CEPH_CSI_USER_KEY}/' \
     deploy/volumes/forgejo-data.hcl | nomad volume create -
   ```

2. `nomad job plan deploy/forgejo.nomad`, then `nomad job run deploy/forgejo.nomad`.

3. Create the admin. There is no web installer (`INSTALL_LOCK`), registration is off.
   The one-time password is a Nomad variable, and the account must change it on first login:

   ```sh
   nomad var put nomad/jobs/forgejo admin_password="$(openssl rand -base64 24)"
   ALLOC=$(nomad job allocs -json forgejo | jq -r '.[] | select(.ClientStatus=="running") | .ID')
   nomad alloc exec -task forgejo "$ALLOC" su-exec git forgejo admin user create \
     --admin --username yan --email yan.guiborat@gmail.com --must-change-password \
     --password "$(nomad var get -item admin_password nomad/jobs/forgejo)"
   ```

   After the first login the variable is stale; `nomad var purge nomad/jobs/forgejo` it.
   A pending password change also blocks API tokens (HTTP 403). For scripted bootstrap
   (migration, mirrors, keys) clear it for the duration and restore it afterwards:

   ```sh
   nomad alloc exec -task forgejo "$ALLOC" su-exec git forgejo admin user must-change-password --unset yan
   nomad alloc exec -task forgejo "$ALLOC" su-exec git forgejo admin user generate-access-token \
     --username yan --token-name bootstrap --raw \
     --scopes write:admin,write:organization,write:repository,write:issue,write:user,write:misc
   # ... API work ...
   curl -u yan -X DELETE http://forgejo.service.consul/api/v1/users/yan/tokens/bootstrap
   nomad alloc exec -task forgejo "$ALLOC" su-exec git forgejo admin user must-change-password yan
   ```

4. Repository `quod/quod` was migrated from https://github.com/netboz/quod with the
   built-in migrator (`POST /api/v1/repos/migrate`, service `github`, issues, pull
   requests, labels, milestones, releases). Without a GitHub token the migrator cannot map
   GitHub accounts, so migrated issues and PRs are authored by `Ghost`; the git history is
   exact. The push mirror back to GitHub is configured in the repository's mirror settings
   with a GitHub fine-grained token (contents: read and write on `netboz/quod`); Forgejo
   stores it in its database, nowhere else.

### Upgrade

Pick the newest tag at https://forgejo.org/releases/ (verify it exists on
`codeberg.org/forgejo/forgejo`), change the `forgejo_version` default, plan, run.
Single allocation: the web UI is down for the restart, the volume re-attaches wherever
the new allocation lands. Forgejo migrates its own database schema on start.

### Secrets

| Secret | Lives in |
|---|---|
| Ceph CSI key (`client.nomad-csi`) | homelab repo `nomad-jobs/volumes/*.hcl` and the Ceph cluster; used only at volume creation |
| Forgejo `SECRET_KEY`, `INTERNAL_TOKEN`, JWT keys | generated on first boot into `/data/gitea/conf/app.ini` on the volume |
| Admin one-time password | Nomad variable `nomad/jobs/forgejo`, key `admin_password` |
| GitHub push-mirror token | the mirror settings of the repository, stored in Forgejo's database only |

### Resource budget

| Task | CPU | Memory | Max | Why |
|---|---|---|---|---|
| forgejo | 500 | 768 MiB | 1536 MiB | measured 113 MiB idle and 125 MiB after the GitHub migration (2026-09-26); git packing and indexing spike, `memory_max` absorbs them without an OOM kill |
| theme (prestart) | 50 | 32 MiB | | copies one CSS file |

### Theme

`deploy/forgejo/theme-quod.css` overrides the stock light theme's palette variables with
the house palette. The prestart task copies it to `/data/gitea/public/assets/css/` and
`[ui] THEMES` / `DEFAULT_THEME` register it. Edit the file, `nomad job run`: the copy
runs again on the restart.

### Moving from SQLite to MariaDB

Not before publication, and only after asking Yan. SQLite serialises writers; the sign is
`database is locked` in the logs or a sluggish UI while runners and several people write at
once. Then: `forgejo dump --database mysql` inside the allocation emits MySQL-syntax SQL,
restore it into MariaDB, switch the `[database]` keys in the job to `mysql`, redeploy.

### Backup and restore

Filled in with the MinIO phase.

## Forgejo Runner and the gates workflow

| | |
|---|---|
| Job | `deploy/forgejo-runner.nomad`, pinned to corin |
| Registered as | runner `corin`, organisation `quod`, label `docker` |
| Job image | `192.168.1.11:5000/quod-ci:28`, built from `deploy/ci/Dockerfile` |
| Cache | Ceph RBD CSI volume `forgejo-runner-cache` (20 GiB) at `/cache` |
| Workflow | `.forgejo/workflows/gates.yml` |

Every push and pull request runs the README gates in order, in one job, on a clean
checkout: `rebar3 as test eunit`, `rebar3 as test ct`, `rebar3 xref`, `rebar3 dialyzer`.
The rebar3 hex cache and the dialyzer PLT come back from the runner's cache, keyed on
`rebar.lock`. On master a second job builds the Dockerfile and pushes
`192.168.1.11:5000/quod:<rebar.config version>`, unless that tag already exists.

### First deploy

1. Build and push the job image: `docker build -t 192.168.1.11:5000/quod-ci:28 deploy/ci`
   then `docker push 192.168.1.11:5000/quod-ci:28`. Rebuild when the release Dockerfile
   moves to a new Erlang base.
2. Create the cache volume the same way as `forgejo-data`, from
   `deploy/volumes/forgejo-runner-cache.hcl`.
3. Register the runner in Forgejo with a shared secret, and store the secrets in Nomad:

   ```sh
   F=$(nomad job allocs -json forgejo | jq -r '.[] | select(.ClientStatus=="running") | .ID')
   SECRET=$(nomad alloc exec -task forgejo "$F" su-exec git forgejo forgejo-cli actions generate-secret)
   nomad alloc exec -task forgejo "$F" su-exec git forgejo forgejo-cli actions register \
     --secret "$SECRET" --name corin --scope quod --labels docker
   nomad var put nomad/jobs/forgejo-runner registration_secret="$SECRET" \
     cache_secret="$(openssl rand -hex 40)"
   ```

4. `nomad job run deploy/forgejo-runner.nomad`. The runner rebuilds its identity from the
   secret at every start, so a restart or a reschedule needs nothing else.

### Rotating the runner secret

Generate a new secret, run `forgejo-cli actions register` again with the same `--name`
and the new secret, `nomad var put` it, and `nomad job run` the runner. Changing
`cache_secret` invalidates the cache; the next run is simply cold.

### Security: the Docker socket

The runner drives corin's Docker daemon through its socket, which is root on corin. The
master release-image job also mounts the socket so it can build and push. Any workflow
that runs on this runner can therefore start, stop or read every container on corin,
including Forgejo, vaultwarden and quod allocations. Only branches and pull requests from
trusted people may run here. Pull requests from forks must not be allowed to run
workflows on this runner.

### Diagnosing a failed job

- `nomad job run -var runner_log_level=debug deploy/forgejo-runner.nomad` puts the runner's
  own diagnostics in its allocation log and in the job logs; redeploy without it after.
- A job container killed by its memory cap exits with code 137. Docker records it as an
  `oom` event on corin; the job log only shows the job as failed.
- If the runner itself is restarted mid-job, its job container is orphaned and keeps
  running on corin. Remove leftovers named `FORGEJO-ACTIONS-TASK-*` with `docker rm -f`.

## Claude review

`.forgejo/workflows/claude-review.yml` runs the Claude Code CLI on each pull request when it
is opened, reopened or marked ready, and posts one comment listing real defects only,
reviewed against AGENTS.md. It uses your Claude subscription, not an API key:

1. On your workstation: `claude setup-token`, copy the token.
2. In Forgejo: organisation `quod`, Settings, Actions, Secrets, add `CLAUDE_CODE_OAUTH_TOKEN`.

To rotate, run `claude setup-token` again and replace the secret. The review is capped at
40 turns and 20 minutes. Pushes to an open pull request do not trigger a new review; close
and reopen it to ask for one.

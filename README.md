# Salesforce DX - GitHub Actions CI/CD Pipeline

This repository automates Salesforce deployments across multiple environments using two parallel pipeline tracks:

- **PR-Based Track** - open/synchronize PRs validate (dry-run); merged PRs deploy. Powered by `template.yaml`.
- **Release/Tag Track** - GitHub Releases or versioned `releases/X.Y.Z` tags deploy a diff between two tags. Powered by `reusable-delta-deploy.yml`.

Additionally, a **Claude AI pre-review** runs on demand via PR comment slash commands before any code reaches the pipeline.

---

## Full Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PR-BASED TRACK                               │
│                                                                     │
│  abc_feature/**  (push)   ──► sf.yaml              ─┐              │
│  staging         (PR open/sync) ──► sf_staging.yaml ─┤             │
│  UAT / uat       (PR open/sync) ──► sf_uat.yaml     ─┼──► template │
│  main / master   (PR open/sync) ──► sf_production    ─┤             │
│  hotfix          (PR open/sync) ──► sf_hotfix.yaml  ─┘              │
│                                                                     │
│  UAT / uat       (PR closed/merged) ──► DeployToUAT.yaml  ─┐       │
│  main / master   (PR closed/merged) ──► DeployToProd.yaml  ─┴──► template
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                      RELEASE / TAG TRACK                            │
│                                                                     │
│  releases/X.Y.Z tag push ──► tag-based-deploy.yaml     ─┐          │
│  GitHub Release published ──► release-based-deploy.yaml ─┴──► reusable-delta-deploy.yml
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                        AI CODE REVIEW                               │
│                                                                     │
│  /analyze (PR comment) ──► salesforce-pr-review.yaml               │
│                             └──► Claude Code Action (Anthropic)     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

  workflow_dispatch ──► dispatch.yaml   (manual utility runs)
```

---

## Workflows at a Glance

| File | Trigger | Environment | Purpose |
|------|---------|-------------|---------|
| `sf.yaml` | Push to `abc_feature/**` | `dev` | Validate on feature push |
| `sf_staging.yaml` | PR opened/sync → `staging` | `staging` | Validate staging PRs |
| `sf_uat.yaml` | PR opened/sync → `UAT`/`uat` | `UAT` | Validate UAT PRs |
| `sf_production.yaml` | PR opened/sync → `main`/`master` | `production` | Validate production PRs |
| `sf_hotfix.yaml` | PR opened/sync → `hotfix` | `hotfix` | Validate hotfix PRs |
| `DeployToUAT.yaml` | PR closed → `UAT`/`uat` | `UAT` | Deploy on UAT merge |
| `DeployToProd.yaml` | PR closed → `main`/`master` | `production` | Deploy on prod merge |
| `tag-based-deploy.yaml` | Push `releases/X.Y.Z` tag | configurable | Tag-triggered delta deploy |
| `release-based-deploy.yaml` | GitHub Release published (`v*`) | configurable | Release delta deploy |
| `salesforce-pr-review.yaml` | `/analyze` PR comment | — | Claude AI code review |
| `template.yaml` | `workflow_call` | — | Shared PR validate + deploy logic |
| `reusable-delta-deploy.yml` | `workflow_call` | — | Shared tag/release delta deploy |
| `validate.yaml` | `workflow_call` | — | Standalone validate helper |
| `dispatch.yaml` | `workflow_dispatch` | — | Manual ad-hoc runs |

---

## PR-Based Track

### Validate Pipelines (PR `opened` / `synchronize`)

All validate pipelines call `template.yaml` with `secrets: inherit` and `runner: macos-latest`.

| Pipeline | Branch | `envionment` | `env_alias` |
|----------|--------|--------------|-------------|
| `sf.yaml` | `abc_feature/**` (push) | `dev` | — |
| `sf_staging.yaml` | `staging` | `staging` | `staging` |
| `sf_uat.yaml` | `UAT` / `uat` | `UAT` | `uat` |
| `sf_production.yaml` | `main` / `master` | `production` | `prod` |
| `sf_hotfix.yaml` | `hotfix` | `hotfix` | `hotfix` |

All pipelines declare explicit permissions:

```yaml
permissions:
  contents: read
  pull-requests: write
  actions: read
```

### Deploy Pipelines (PR `closed` / merged)

Separate workflows handle the actual deployment when a PR is merged:

| Pipeline | Branch | `envionment` | `env_alias` |
|----------|--------|--------------|-------------|
| `DeployToUAT.yaml` | `UAT` / `uat` | `UAT` | `uat` |
| `DeployToProd.yaml` | `main` / `master` | `production` | `prod` |

Both call `template.yaml`. The template distinguishes PR events from merge events internally using `github.event.pull_request.merged` and `github.event.action`.

---

## template.yaml - Common Pipeline Steps

### Setup Phase (always runs)

```
 1. Checkout code                  (fetch-depth: 0)
 2. Setup Node.js                  (>=24)
 3. Setup Java                     (>=11, Zulu distribution)
 4. Setup Python                   (>=3.10)
 5. Read PR Body                   (READ_PRBODY.py → apex_test_classes env var)
 6. Update .env.<env_alias> file   (inject AWS_ACCESS_KEY, AWS_ACCESS_SECRET, SITE_ADMIN, SITE_DOMAIN)
 7. Load .env file                 (xom9ikk/dotenv@v2, mode: <env_alias>)
 8. Install Salesforce CLI         (npm install -g @salesforce/cli)
 9. Verify SF CLI version
10. Install SF Code Analyzer       (open PRs only)
11. Install SFDX Git Delta         (sfdx-git-delta plugin)
12. Generate Delta Files           (sf sgd source delta HEAD~1 → HEAD, API 66.0 → ./delta)
13. Decrypt server.key             (AES-256-CBC via openssl)
14. Authenticate with Salesforce   (sf org login jwt)
```

### PR Phase - `opened` / `synchronize` (validate only, `--dry-run`)

```
15. Run Salesforce Code Analyzer        (open PRs only)
16. Quality Gate                        (fail on Sev1/Sev2 or >10 total violations)
17. SonarQube Scan                      (open PRs only, SonarSource/sonarqube-scan-action@v8)
18a. Validate - With Specific Tests     (apex_test_classes != 'No Apex classes found')
18b. Validate - Default Test Level      (apex_test_classes == 'No Apex classes found')
18c. Validate - RunRelevantTests        (apex_test_classes == 'RunRelevantTests')
19. Enforce 82% Code Coverage           (CODE_COVERAGE.py deploy-result.json)
20. Validate Pre-Destructive Changes    (if <types> in destructiveChanges/destructiveChanges.xml)
21. Post Validation Job ID as PR Comment (hidden comment: <!-- sf-validation-id -->)
```

### Merge Phase - PR `closed` + `merged == true` (actual deploy)

```
22. Read Validation Job ID from PR Comment
23. Deploy Pre-Destructive Changes      (if <types> in destructiveChanges/destructiveChanges.xml)
24. Quick Deploy                        (reuse validated job ID, skip test re-runs)
    └─ fallback if expired/failed ──►
25a. Deploy - RunRelevantTests          (if no quick deploy and apex_test_classes == 'RunRelevantTests')
25b. Deploy - Default Test Level        (if no quick deploy and apex_test_classes == 'No Apex classes found')
25c. Deploy - With Specific Tests       (if no quick deploy and apex_test_classes != 'No Apex classes found')
26. Deploy Post-Destructive Changes     (if <types> in destructiveChanges/postDestructiveChanges.xml)
```

### Notification Phase (always runs)

```
27. Notify Slack via curl  (status emoji, workflow, repo, branch, actor, event, run URL)
```

---

## Release / Tag Track

Both release and tag pipelines are two-job workflows: **resolve tags → delegate to `reusable-delta-deploy.yml`**.

### `tag-based-deploy.yaml`

| Property | Value |
|----------|-------|
| Trigger | Push to `releases/[1-9]+.[0-9]+.[0-9]+` tags |
| Manual | `workflow_dispatch` with `environment`, `test_level`, `tag_name` inputs |
| Job 1 | `resolve-tags` - extracts current tag from `GITHUB_REF`, finds previous `releases/*` tag via `git describe` |
| Job 2 | `deploy` - calls `reusable-delta-deploy.yml` with resolved tags |
| Condition | `startsWith(github.ref, 'refs/tags/releases/')` or `workflow_dispatch` |

### `release-based-deploy.yaml`

| Property | Value |
|----------|-------|
| Trigger | GitHub Release published (non-prerelease, tag must start with `v`) |
| Manual | `workflow_dispatch` with `environment`, `test_level`, `release_tag` inputs |
| Job 1 | `resolve-tags` - reads `github.event.release.tag_name`, finds previous tag via `git describe` |
| Job 2 | `deploy` - calls `reusable-delta-deploy.yml` with resolved tags |
| Condition | Tag starts with `v` and `prerelease == false` |

**Manual dispatch inputs (both workflows):**

| Input | Options | Default |
|-------|---------|---------|
| `environment` | `production`, `Staging`, `UATInt`, `DevInt` | required |
| `test_level` | `NoTestRun`, `RunLocalTests`, `RunAllTestsInOrg`, `RunRelevantTests` | `RunRelevantTests` |
| `release_tag` / `tag_name` | Free text (leave empty for HEAD/triggered tag) | optional |

### `reusable-delta-deploy.yml` - Shared Delta Deploy Steps

Called by both tag and release pipelines via `workflow_call`.

| Input | Description |
|-------|-------------|
| `environment` | GitHub Environment name |
| `current_tag` | Git ref/tag to deploy up to |
| `previous_tag` | Git ref/tag to diff from (empty = full deploy) |
| `test_level` | Apex test level (default: `RunLocalTests`) |

**Steps:**

```
1. Checkout source (fetch-depth: 0)
2. Setup Node.js 20
3. Cache Salesforce CLI (actions/cache@v4, keyed to workflow file hash)
4. Configure npm global directory
5. Install Salesforce CLI + sfdx-git-delta  (skipped on cache hit)
6. Generate Delta Package                    (sgd between previous_tag → current_tag)
   └─ If no previous tag: full source deploy
   └─ Outputs has_delta=true/false
7. Authenticate to Salesforce               (JWT, key written to temp file, deleted after auth)
8. Run Apex Tests                           (skipped if test_level == 'NoTestRun')
9. Deploy Delta                             (skipped if has_delta == false)
10. Deploy Destructive Changes              (only if main deploy succeeded)
11. Write Deployment Summary                (always - markdown table to $GITHUB_STEP_SUMMARY)
```

**Secrets required by `reusable-delta-deploy.yml`:**

| Secret | Description |
|--------|-------------|
| `SF_SERVER_KEY` | PEM content of the JWT private key (not a file path - raw key content) |
| `SF_CONSUMER_KEY` | External Client App consumer key |
| `SF_USERNAME` | Salesforce deployment username |
| `SF_INSTANCE_URL` | `https://login.salesforce.com` or `https://test.salesforce.com` |
| `TEAMS_WEBHOOK_URL` | Microsoft Teams webhook URL (optional) |

---

## Claude AI Pre-Review (`salesforce-pr-review.yaml`)

An on-demand AI code review powered by **Claude Code Action** (`anthropics/claude-code-action@v1`). Triggered by slash commands in any PR comment (non-bot users only).

### Trigger Commands

| Comment | Review Type |
|---------|-------------|
| `/analyze` | General Salesforce code review |
| `/analyze failure` | Review and explain a CI/deployment failure |
| `/analyze issue` | Investigate a specific bug or issue |
| `/analyze build` | Review build/deployment pipeline problems |

### Review Coverage

Claude performs a **Salesforce-specific** review across 10 focus areas:

1. **Apex Code Quality** - bulkification, SOQL/DML outside loops, governor limits, trigger framework, exception handling, naming conventions
2. **Security & Sharing** - CRUD/FLS checks, SOQL injection, XSS prevention, `with sharing` usage, `@AuraEnabled` security, no hardcoded credentials
3. **Lightning Web Components** - `@api`/`@track`/`@wire` usage, event handling, error handling, accessibility, performance
4. **Test Coverage & Quality** - minimum 75% coverage, `Test.startTest()`/`stopTest()`, bulk testing (200+ records), `System.runAs()`, no `SeeAllData=true`
5. **SOQL/SOSL Optimization** - selective queries, indexed fields, query limits, aggregate functions
6. **Integration & API** - callout limits, async processing (`@future`, Queueable, Batch), Named Credentials, retry logic
7. **Platform Features** - Custom Metadata, Platform Events, Flow vs code trade-offs, Schema Describe caching, Platform Cache
8. **Documentation** - JavaDoc headers, inline comments for complex logic, README updates
9. **Deployment & Package Structure** - `sfdx-project.json`, `package.xml`, destructive changes review
10. **Anti-Patterns** - queries/DML in loops, hardcoded IDs, recursive triggers, missing null checks

### Output Format

Claude posts inline PR comments with:
- **Severity levels**: Critical, Warning, Suggestion
- **File paths and line numbers** for specific issues
- **Code improvement examples**
- **Governor limit risk flags**

### Required Secret

| Secret | Description |
|--------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude access |

### Permissions

```yaml
permissions:
  contents: read
  pull-requests: write
  id-token: write
  actions: read
```

---

## PR Body Format - Apex Test Class Parsing

`READ_PRBODY.py` parses the PR description to extract Apex test class names using the format defined in the [PR template](.github/pull_request_template.md):

```
APEX TEST CLASS TO RUN [RUN:]
TestClass1,TestClass2
```

The parsed value is stored in the `apex_test_classes` environment variable:

| `apex_test_classes` value | Validate step | Deploy step |
|---------------------------|---------------|-------------|
| Specific class names | `RunSpecifiedTests --tests <classes>` | `RunSpecifiedTests --tests <classes>` |
| `RunRelevantTests` | `RunRelevantTests` | `RunRelevantTests` |
| `No Apex classes found` | Default test level | Default test level |

---

## Quick Deploy Pattern

Avoids re-running tests on merge by reusing the Salesforce validation job from the open PR:

```
PR Opened/Sync  →  Validate (dry-run)  →  Extract job ID from deploy-result.json
                                        →  Post ID as hidden PR comment (<!-- sf-validation-id -->)
                                        →  Clean up any previous validation comments

PR Merged       →  Read validation ID from PR comment
                →  sf project deploy quick --job-id <id>   (skips test re-run)
                →  Falls back to full deploy if quick deploy fails or ID expired
```

---

## Delta Deployment (SFDX Git Delta)

Only changed metadata is deployed. Used in both pipeline tracks:

**PR track** (`template.yaml`) - diffs `HEAD~1` → `HEAD`:
```bash
sf sgd source delta \
  --from "HEAD~1" --to "HEAD" \
  --generate-delta --ignore-file .sgdignore \
  --output-dir ./delta --ignore-whitespace \
  --api-version 66.0 --source-dir force-app/main/default
```

**Release/Tag track** (`reusable-delta-deploy.yml`) - diffs `previous_tag` → `current_tag`:
```bash
sf sgd source delta \
  --from "$PREVIOUS_TAG" --to "$CURRENT_TAG" \
  --output delta/ --generate-delta
```

If no previous tag exists (first deployment), the full source is deployed.

---

## Authentication - JWT Flow

**PR-based track** (template.yaml) - decrypts an encrypted key file stored in the repo:
```bash
# Step 1: Decrypt
openssl enc -nosalt -aes-256-cbc -d \
  -in <ENCRYPTION_KEY_FILE> -out <JWT_KEY_FILE> \
  -base64 -K <DECRYPTION_KEY> -iv <DECRYPTION_IV>

# Step 2: Login
sf org login jwt \
  --client-id <CONSUMER_KEY> \
  --jwt-key-file <JWT_KEY_FILE> \
  --username <DEPLOYMENT_USER_USERNAME> \
  --set-default --alias <ORG_DEFAULT_ALIAS> \
  --instance-url <HUB_LOGIN_URL>
```

**Release/Tag track** (reusable-delta-deploy.yml) - writes PEM key content from secret directly to temp file:
```bash
printf '%s' "$SF_SERVER_KEY" > sf_server.key
sf org login jwt \
  --client-id "$SF_CONSUMER_KEY" \
  --jwt-key-file sf_server.key \
  --username "$SF_USERNAME" \
  --instance-url "$SF_INSTANCE_URL" \
  --alias "$environment" --set-default
rm -f sf_server.key
```

---

## One-Time Setup

### Step 1 - Generate the Certificate

```bash
openssl genpkey -aes-256-cbc -algorithm RSA \
  -pass pass:<YOUR_PASSPHRASE> \
  -out assets/dev/server.pass.key -pkeyopt rsa_keygen_bits:2048

openssl rsa -passin pass:<YOUR_PASSPHRASE> \
  -in assets/dev/server.pass.key -out assets/dev/server.key

openssl req -new -key assets/dev/server.key -out assets/dev/server.csr

openssl x509 -req -sha256 -days 365 \
  -in assets/dev/server.csr \
  -signkey assets/dev/server.key -out assets/dev/server.crt
```

### Step 2 - Create an External Client App in Salesforce

1. Go to **Setup > External Client Apps > New External Client App**.
2. Enable **OAuth Settings**.
3. Set the callback URL to `http://localhost:1717/OauthRedirect`.
4. Upload `server.crt` under **Use Digital Signatures**.
5. Add the required OAuth scopes (API, refresh token, etc.).
6. Note the **Consumer Key** - this is your `CONSUMER_KEY` / `SF_CONSUMER_KEY` secret.

### Step 3 - Encrypt the Private Key (PR-based track)

```bash
# Generate AES-256 key and IV
openssl enc -aes-256-cbc -k <YOUR_PASSPHRASE> -P -md sha1 -nosalt

# Encrypt
openssl enc -nosalt -aes-256-cbc \
  -in assets/dev/server.key \
  -out assets/dev/server.key.enc \
  -base64 -K <KEY> -iv <IV>
```

Commit `assets/dev/server.key.enc`. **Never commit the raw `server.key`.**

For the **Release/Tag track** - store the raw PEM content of `server.key` directly in the `SF_SERVER_KEY` GitHub secret.

### Step 4 - Authenticate Locally (verification)

```bash
sf org login jwt \
  --client-id <YOUR-CLIENT-ID> \
  --jwt-key-file assets/dev/server.key \
  --username <deployment-user-name> \
  --set-default --alias DEV_INT_ORG \
  --instance-url https://test.salesforce.com
```

---

## GitHub Environments & Secrets

Create GitHub Environments (`dev`, `staging`, `UAT`, `production`, `hotfix`) under **Settings > Environments**.

### Secrets - PR-Based Track (per environment)

| Secret | Description |
|--------|-------------|
| `CONSUMER_KEY` | External Client App client ID |
| `ENCRYPTION_KEY` | AES encryption key |
| `DECRYPTION_KEY` | AES key to decrypt `server.key.enc` at runtime |
| `DECRYPTION_IV` | AES IV to decrypt `server.key.enc` at runtime |
| `ENCRYPTION_KEY_FILE` | Path to encrypted key (e.g. `assets/dev/server.key.enc`) |
| `JWT_KEY_FILE` | Path for decrypted key at runtime (e.g. `assets/dev/server.key`) |
| `DEPLOYMENT_USER_USERNAME` | Salesforce deployment username |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |
| `SLACK_API_KEY` | Slack API key |
| `SONAR_TOKEN` | SonarQube authentication token |
| `AWS_ACCESS_KEY` | AWS access key (injected into .env file) |
| `AWS_ACCESS_SECRET` | AWS secret (injected into .env file) |
| `SITE_ADMIN` | Site admin credential (injected into .env file) |
| `SITE_DOMAIN` | Site domain (injected into .env file) |

### Secrets - Release/Tag Track (per environment)

| Secret | Description |
|--------|-------------|
| `SF_SERVER_KEY` | Raw PEM content of the JWT private key |
| `SF_CONSUMER_KEY` | External Client App consumer key |
| `SF_USERNAME` | Salesforce deployment username |
| `SF_INSTANCE_URL` | `https://login.salesforce.com` or `https://test.salesforce.com` |
| `TEAMS_WEBHOOK_URL` | Microsoft Teams webhook URL (optional) |

### Secret - AI Review

| Secret | Description |
|--------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude Code Action |

### Variables (per environment, PR-based track)

| Variable | Example | Description |
|----------|---------|-------------|
| `ORG_DEFAULT_ALIAS` | `DEV_INT_ORG` | Salesforce org alias |
| `HUB_LOGIN_URL` | `https://test.salesforce.com` | Login URL |
| `NODE_VERSION` | `>=24` | Node.js version |
| `SF_CLI_VERSION` | `latest` | Salesforce CLI version |
| `PYTHON_VERSION` | `>=3.10` | Python version |
| `ORGANIZATION_VARIABLE` | — | Shared org-level variable |

---

## Code Quality Gates

### Salesforce Code Analyzer (open PRs only)

`forcedotcom/run-code-analyzer@v2` scans the full workspace. Artifacts: `sfca_results.html`, `sfca_results.json`.

| Condition | Threshold |
|-----------|-----------|
| Severity 1 violations | > 0 |
| Severity 2 violations | > 0 |
| Total violations | > 10 |

### SonarQube (open PRs only)

`SonarSource/sonarqube-scan-action@v8` with Apex configuration:

| Setting | Value |
|---------|-------|
| Language | `apex` |
| Coverage inclusions | `**/*Test.cls` |
| Exclusions | `.cmp`, `fflib_*.cls`, `.yml`, `.js`, `.xml`, `.css`, `.html`, web fonts, SVGs, static resources |

### Code Coverage Enforcement (open PRs only)

`CODE_COVERAGE.py` parses `deploy-result.json` and enforces **minimum 82% Apex coverage**. The job fails if below threshold.

---

## Destructive Changes

Supported in both validate and deploy phases:

| File | Validated on | Deployed on |
|------|-------------|-------------|
| `destructiveChanges/destructiveChanges.xml` | Open PR (dry-run, pre) | Merge (before main deploy) |
| `destructiveChanges/postDestructiveChanges.xml` | — | Merge (after main deploy) |

Both steps are skipped if no `<types>` are present in the XML file.

---

## Branch Strategy

```
abc_feature/**  →  Dev     (push → validate)
staging         →  Staging (PR open/sync → validate)
UAT / uat       →  UAT     (PR open/sync → validate | PR merged → deploy)
main / master   →  Prod    (PR open/sync → validate | PR merged → deploy)
hotfix          →  Hotfix  (PR open/sync → validate)
releases/X.Y.Z  →  any env (tag push → delta deploy between tags)
v* release      →  any env (GitHub Release → delta deploy between tags)
```

---

## Deployment Summary (Release/Tag Track)

After every release/tag deployment, a markdown summary is written to `$GITHUB_STEP_SUMMARY` in the Actions run:

| Field | Value |
|-------|-------|
| Environment | Target environment |
| Current Tag | Tag being deployed |
| Previous Tag | Tag diffed from (or `N/A` for first deploy) |
| Test Level | Apex test level used |
| Status | success / failure |
| Triggered by | GitHub actor |
| Run URL | Direct link to Actions run |
| Deployed Components | `package.xml` contents |
| Destructive Changes | `destructiveChanges.xml` contents (if any) |

---

## Tool Versions

| Tool | PR Track | Release/Tag Track |
|------|----------|-------------------|
| Salesforce CLI | `latest` | `latest` |
| Node.js | `>=24` | `20` (cached) |
| Java (Zulu) | `>=11` | — |
| Python | `>=3.10` | — |
| SF API (delta) | `66.0` | auto (sgd default) |
| SF API (source) | `65.0` | — |
| Runner (callers) | `macos-latest` | `ubuntu-latest` |

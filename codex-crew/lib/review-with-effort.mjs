#!/usr/bin/env node
// review-with-effort — run codex's ADVERSARIAL review at a per-dispatch
// reasoning effort, without patching or forking the codex plugin.
//
// Why this file exists: codex-companion's `adversarial-review` cannot set
// reasoning effort. Its parser knows only --base/--scope/--model/--cwd
// (codex-companion.mjs:713), executeReviewRun never receives an effort
// (:742), and the adversarial branch calls runAppServerTurn without one
// (:411) — so lib/codex.mjs:1140 sends `effort: null` to turn/start and the
// turn runs at whatever model_reasoning_effort the codex config carries. The
// WIRE protocol accepts effort; only the companion's plumbing is missing (the
// `task` path proves it — same runAppServerTurn call, effort threaded).
//
// So instead of editing vendor code (which lives under ~/.claude/plugins and
// is replaced wholesale on every version bump), this driver imports the same
// PUBLIC exports executeReviewRun uses and re-composes them, adding `effort`.
// Everything it produces — job id prefix, kind, kindLabel, jobClass, title,
// summary, payload shape, log file — matches a vendor-created review, so
// `crew-codex status`, `await`, `result` and `cancel` work unchanged on it.
//
// The composition is a supported-by-accident contract: these are internal
// vendor modules that merely happen to be `export`ed. Upstream can rename them
// at any release, so every import is checked and a miss is LOUD (see
// vendorContractFailure) — never a silent fallback to the vendor path, which
// would run a review at the wrong effort while the caller believed otherwise.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const SELF_PATH = fileURLToPath(import.meta.url);

// Duplicated from VALID_REASONING_EFFORTS at codex-companion.mjs:71
// (codex@openai-codex v1.0.6). That constant is NOT exported, so it cannot be
// imported like everything else here — this copy is deliberate and must be
// re-checked whenever the codex plugin is bumped.
//
// Capped at `xhigh` ON PURPOSE. The model registry advertises higher
// `max`/`ultra` tiers and this driver bypasses the vendor's validator entirely,
// so nothing upstream would stop them — but whether the app-server accepts
// them on a turn/start is UNTESTED. Do not widen this set without proving it
// end to end against a real turn.
const VALID_REASONING_EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh"];

// The vendor's set is the RUNTIME's contract, not any one model's. Verified
// against the account (devops docs/ai/codex-crew-setup.md): the GPT-5.6 family
// returns a 400 on reasoning.effort for `none` and `minimal`, so the usable
// ladder on the models we actually dispatch (sol/terra/luna) starts at `low`.
// gpt-6-astra rejects the same two. We still ACCEPT all six — another model
// family may take them, and pinning the wrapper to one family's limits would be
// wrong, which is why VALID_REASONING_EFFORTS above is deliberately NOT narrowed
// — but we warn, because otherwise the failure surfaces as an opaque API 400
// minutes into a job rather than as a predictable consequence of the flag.
const EFFORTS_REJECTED_BY_STRICT_MODELS = new Set(["none", "minimal"]);

// One row per model family known to 400 on `none`/`minimal`. A row carries its
// own wording so the warning names the family the caller actually asked for
// rather than a family they never mentioned. Add a row when a new lane is
// ported; do not bolt a second regex onto the call site.
const MINIMAL_EFFORT_REJECTING_MODELS = [
  {
    pattern: /^gpt-5\.6/i,
    label: "the GPT-5.6 family",
    ladder: "The usable ladder on gpt-5.6-sol/terra/luna is low|medium|high|xhigh."
  },
  {
    pattern: /^gpt-6-astra/i,
    label: "gpt-6-astra",
    ladder: "The usable ladder on gpt-6-astra is low|medium|high|xhigh."
  }
];

// A null/blank model means the codex config picks one, and that default is a
// 5.6 model here — so an absent model is treated as 5.6 too. A false warning
// costs a line of stderr; a missed one costs a whole job.
function modelRejectsMinimalEfforts(model) {
  const name = String(model ?? "").trim();
  if (name === "") {
    return MINIMAL_EFFORT_REJECTING_MODELS[0];
  }
  return MINIMAL_EFFORT_REJECTING_MODELS.find((entry) => entry.pattern.test(name)) ?? null;
}

const REVIEW_NAME = "Adversarial Review";
const JOB_TITLE = "Codex Adversarial Review";

const EXIT_USAGE = 2;
// Distinct from the usage exit so a caller can tell "you passed a bad flag"
// from "the vendor plugin changed shape under us".
const EXIT_VENDOR_CONTRACT = 3;

// Every vendor symbol this driver composes, grouped by the module that must
// export it. Presence is verified at load time; see loadVendorModules.
const VENDOR_MODULES = [
  { file: ["scripts", "lib", "git.mjs"], symbols: ["resolveReviewTarget", "collectReviewContext"] },
  { file: ["scripts", "lib", "prompts.mjs"], symbols: ["loadPromptTemplate", "interpolateTemplate"] },
  { file: ["scripts", "lib", "codex.mjs"], symbols: ["runAppServerTurn", "readOutputSchema", "parseStructuredOutput"] },
  { file: ["scripts", "lib", "render.mjs"], symbols: ["renderReviewResult"] },
  { file: ["scripts", "lib", "workspace.mjs"], symbols: ["resolveWorkspaceRoot"] },
  { file: ["scripts", "lib", "state.mjs"], symbols: ["generateJobId", "upsertJob", "writeJobFile"] },
  {
    file: ["scripts", "lib", "tracked-jobs.mjs"],
    symbols: [
      "createJobRecord",
      "createJobLogFile",
      "createJobProgressUpdater",
      "createProgressReporter",
      "runTrackedJob",
      "appendLogLine"
    ]
  }
];

const VALUE_OPTIONS = new Set([
  "plugin-root",
  "plugin-version",
  "cwd",
  "base",
  "scope",
  "model",
  "effort",
  "job-id",
  "job-file"
]);
// `wait` is accepted and ignored, exactly as the companion treats it on the
// review path: inline IS the default, so the flag only exists to be explicit.
const BOOLEAN_OPTIONS = new Set(["json", "background", "wait", "worker"]);
const ALIAS_MAP = { m: "model", C: "cwd" };

// Mirrors lib/args.mjs parseArgs, including its most load-bearing behavior:
// an UNRECOGNIZED --flag becomes a positional (i.e. review focus text) rather
// than an error. crew-codex's guard tests depend on that shape, and diverging
// here would make --effort dispatches reject argv the vendor path accepts.
function parseArgv(argv) {
  const options = {};
  const positionals = [];
  let passthrough = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (passthrough) {
      positionals.push(token);
      continue;
    }
    if (token === "--") {
      passthrough = true;
      continue;
    }
    if (!token.startsWith("-") || token === "-") {
      positionals.push(token);
      continue;
    }

    if (token.startsWith("--")) {
      const [rawKey, inlineValue] = token.slice(2).split("=", 2);
      const key = ALIAS_MAP[rawKey] ?? rawKey;

      if (BOOLEAN_OPTIONS.has(key)) {
        options[key] = inlineValue === undefined ? true : inlineValue !== "false";
        continue;
      }
      if (VALUE_OPTIONS.has(key)) {
        const nextValue = inlineValue ?? argv[index + 1];
        if (nextValue === undefined) {
          usageFailure(`Missing value for --${rawKey}.`);
        }
        options[key] = nextValue;
        if (inlineValue === undefined) {
          index += 1;
        }
        continue;
      }
      positionals.push(token);
      continue;
    }

    const shortKey = token.slice(1);
    const key = ALIAS_MAP[shortKey] ?? shortKey;
    if (BOOLEAN_OPTIONS.has(key)) {
      options[key] = true;
      continue;
    }
    if (VALUE_OPTIONS.has(key)) {
      const nextValue = argv[index + 1];
      if (nextValue === undefined) {
        usageFailure(`Missing value for -${shortKey}.`);
      }
      options[key] = nextValue;
      index += 1;
      continue;
    }
    positionals.push(token);
  }

  return { options, positionals };
}

function errorLines(lines) {
  for (const line of lines) {
    process.stderr.write(`crew-codex: ${line}\n`);
  }
}

function usageFailure(message) {
  errorLines([message]);
  process.exit(EXIT_USAGE);
}

// The loud failure this feature depends on. A silent fallback to the vendor
// review path would run a credential/security review at the config's effort
// while the caller believed it ran at the effort they asked for — the exact
// failure mode this driver exists to prevent. So: name the version, the
// module and the symbol, tell the caller how to proceed deliberately, and die.
function vendorContractFailure({ pluginRoot, pluginVersion, modulePath, symbol, cause }) {
  const what = symbol
    ? `does not export \`${symbol}\``
    : "could not be imported";
  errorLines([
    `cannot run an adversarial review at an explicit --effort.`,
    `codex@openai-codex ${pluginVersion} ${what} from ${modulePath}.`,
    cause ? `underlying error: ${cause}` : null,
    `this driver composes the codex plugin's internal modules to add --effort, which`,
    `the vendor review path does not support; an upstream rename breaks it.`,
    `re-run WITHOUT --effort to use the vendor review path — it still works, and runs`,
    `at model_reasoning_effort from ${process.env.CODEX_HOME ?? "~/.codex"}/config.toml.`,
    `refusing to fall back automatically: that would run this review at an effort you`,
    `did not ask for while reporting success.`,
    `plugin root: ${pluginRoot}`
  ].filter(Boolean));
  process.exit(EXIT_VENDOR_CONTRACT);
}

async function loadVendorModules(pluginRoot, pluginVersion) {
  const loaded = {};

  for (const spec of VENDOR_MODULES) {
    const modulePath = path.join(pluginRoot, ...spec.file);
    let mod;
    try {
      mod = await import(pathToFileURL(modulePath).href);
    } catch (error) {
      vendorContractFailure({
        pluginRoot,
        pluginVersion,
        modulePath,
        symbol: null,
        cause: error instanceof Error ? error.message : String(error)
      });
    }

    for (const symbol of spec.symbols) {
      if (typeof mod[symbol] !== "function") {
        vendorContractFailure({ pluginRoot, pluginVersion, modulePath, symbol, cause: null });
      }
      loaded[symbol] = mod[symbol];
    }
  }

  return loaded;
}

function resolvePluginVersion(pluginRoot, explicit) {
  if (explicit) {
    return explicit;
  }
  try {
    const manifest = JSON.parse(
      fs.readFileSync(path.join(pluginRoot, ".claude-plugin", "plugin.json"), "utf8")
    );
    return manifest.version ?? "unknown";
  } catch {
    return "unknown";
  }
}

// Local copy of codex-companion.mjs:174 — not exported, and only used for the
// job summary fallback.
function firstMeaningfulLine(text, fallback) {
  const line = String(text ?? "")
    .split(/\r?\n/)
    .map((value) => value.trim())
    .find(Boolean);
  return line ?? fallback;
}

// Collector skip markers, counted ONLY in their structural position.
//
// The vendor emits an unusable changed file as exactly two lines — a `### <path>`
// heading followed by `(skipped: <reason>)` (lib/git.mjs:196-219) — and inlines
// every usable untracked file's RAW CONTENT a few lines later, inside a fence.
// A regex scan of the whole blob therefore counts markers that are file content:
// any reviewed file that itself contains a `(skipped: ...)` line (a test fixture,
// a pasted log, this very comment in a diff) inflated the count, and once the
// count reached fileCount the driver REFUSED a perfectly reviewable diff.
//
// So: a marker counts only when the preceding line is a `### <path>` heading AND
// — when changedFiles is usable — that path is a genuinely changed file. Both
// conditions must hold, which also bounds the result by fileCount by
// construction (changedFiles is where fileCount comes from). Returns the PATHS,
// never the marker text: callers put this in error messages and job logs, and
// the marker text can be a fragment of someone's file.
//
// Two ways that structural test was still ambiguous, and both are handled here:
//
// OVER-COUNT — the changed-path cross-check does not save us when the colliding
// text names a REAL changed file. The collector inlines untracked files raw
// inside a fence, so reviewing a doc that quotes the collector's own output
// ("### notes.md" then "(skipped: example)") produced a marker for a path that
// is genuinely in changedFiles, and once the count reached fileCount the driver
// REFUSED a reviewable diff. Fenced regions are therefore tracked and skipped:
// inside a fence every line is file CONTENT, never collector structure.
//
// UNDER-COUNT — the heading capture used to be `(.+?)\s*$`, trimming trailing
// whitespace off the path before the membership test. A changed path that
// really ends in spaces (git happily tracks one) then never matched its own
// heading, the marker was not counted, and an all-skipped context could be
// dispatched as a blind review. The path is now captured and compared EXACTLY;
// the vendor renders `### ${file}`, so any trailing space in the heading is part
// of the filename.
function collectSkippedFiles(content, changedFiles) {
  const lines = String(content ?? "").split(/\r?\n/);
  const changed = Array.isArray(changedFiles) && changedFiles.length > 0
    ? new Set(changedFiles.map((file) => String(file)))
    : null;
  const paths = new Set();
  // The marker that opened the region we are inside, or null at top level.
  // CommonMark rules, minus what cannot occur here: an opening fence may carry
  // an info string, a closing fence may not, and a closing fence must use the
  // same character and be at least as long. An UNTERMINATED fence in inlined
  // content therefore swallows the rest of the blob — deliberately, because
  // that is what a Markdown reader does with it too, and because the failure
  // direction (fewer markers, so a review is dispatched with a warning) beats
  // refusing a reviewable diff outright.
  let fence = null;
  for (let i = 0; i < lines.length; i += 1) {
    const fenceLine = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(lines[i]);
    if (fenceLine) {
      const [, marker, info] = fenceLine;
      if (fence === null) {
        fence = marker;
      } else if (marker[0] === fence[0] && marker.length >= fence.length && info.trim() === "") {
        fence = null;
      }
      continue;
    }
    if (fence !== null) continue;
    if (i + 1 >= lines.length) break;
    const heading = /^### (.+)$/.exec(lines[i]);
    if (!heading) continue;
    if (!/^\(skipped: .*\)\s*$/.test(lines[i + 1])) continue;
    const file = heading[1];
    // Cross-check against the changed-file list where we have one. Without it
    // (a vendor rename, or a target that reports none) fall back to structural
    // position alone — still far tighter than a whole-blob regex.
    if (changed && !changed.has(file)) continue;
    paths.add(file);
  }
  return [...paths];
}

// ---- the sensitivity gate: a code-enforced FLOOR on review effort ---------
//
// ⚠️ THIS IS A SECURITY CONTROL, not a convenience. codex-reviewer.md has
// always PROMISED `xhigh` when a diff touches auth, credentials, Terraform or
// CI — but that promise lived in agent prose, and the same file forbids the
// forwarding agent from inspecting the repository, so nothing ever read the
// diff to check. The escalation therefore fired only when the human caller
// happened to DESCRIBE the change that way; an unannotated "adversarially
// review this branch" ran a real Terraform change at the lane default. This
// classifier closes that gap: it reads the changed-file list the review is
// built from, and raises the effort with no way for prose to disagree.
//
// ⚠️ WIDENING THESE LISTS IS ALWAYS SAFE. The worst case is a review that costs
// more than it strictly needed to. NARROWING THEM NEEDS REVIEW: every pattern
// removed is a class of change that silently drops back to the lane default,
// which is precisely the failure this exists to remove. Add first, argue later.
//
// ⚠️ Every pattern below is NON-GLOBAL on purpose. A `/g` regex carries
// lastIndex between .test() calls, so the second file matched against it would
// be tested from an offset and could report "not sensitive" — a stateful
// security check that fails open on the second hit.
const SENSITIVITY_FLOOR_EFFORT = "xhigh";
const SENSITIVITY_OVERRIDE_ENV = "CREW_CODEX_SENSITIVITY_OVERRIDE";
// Enough to identify the change; a 400-file diff must not bury the reason in
// its own evidence.
const SENSITIVITY_PATHS_SHOWN = 8;

// The auth/identity vocabulary, kept as ONE list because it feeds TWO
// anchorings below, and a security control whose vocabulary lives in two places
// grows two different vocabularies. The full words sit beside the abbreviated
// stems deliberately: an abbreviations-only list read `internal/authentication/`
// and `services/authorization/` — what real trees are actually called — as
// ordinary source, and `identity` was absent altogether.
//
// Order is cosmetic, not load-bearing: JS alternation is leftmost-first but
// backtracks into the later branches, so `auth` before `authentication` still
// matches `authentication/`. Longest-first simply reads as the intent.
const AUTH_SOURCE_TERMS = [
  "authentication", "authorization", "authn", "authz", "auth",
  "oauth2?", "oidc", "saml", "sso", "iam", "identity", "rbac",
  "login", "logout", "session", "jwt", "token", "crypto",
  "keyvault", "kms", "vault", "permissions?"
];

// `auth` -> `[Aa]uth`. ONLY the first letter is made case-flexible, and that
// restraint is the entire false-positive story of the CamelCase anchoring: a
// per-letter case-insensitive term followed by an uppercase boundary matches
// `AUTHORS`, a file at the root of a great many repositories. `[Aa]uth[A-Z]`
// does not, while still covering `AuthService.ts` and `authService.ts`.
// Accepted consequence: an all-caps acronym run together with a capitalised
// word (`SSOManager.ts`) is NOT caught by this anchoring — the segment rule
// still catches `sso/` and `sso-manager.ts`.
function camelCaseTermPattern(term) {
  const first = term[0];
  return `[${first.toUpperCase()}${first}]${term.slice(1)}`;
}

// Anchoring 1 — whole path SEGMENT, or the start of one up to a `.`/`_`/`-`.
// Unchanged in shape from the original rule; only the vocabulary widened.
const AUTH_SOURCE_SEGMENT_PATTERN = new RegExp(
  `(^|/)(${AUTH_SOURCE_TERMS.join("|")})([._-][^/]*)?(/|$)`,
  "i"
);

// Anchoring 2 — a sensitive term as the LEADING CamelCase component of a
// segment: `AuthService.ts`, `IdentityProvider.ts`, `TokenStore/index.ts`.
// Deliberately NOT `/i`: the required uppercase letter after the term is the
// only thing separating `AuthService` from `author`, and a case-insensitive
// boundary would erase it.
const AUTH_SOURCE_CAMEL_PATTERN = new RegExp(
  `(^|/)(${AUTH_SOURCE_TERMS.map(camelCaseTermPattern).join("|")})[A-Z][^/]*(/|$)`
);

// Matched against each CHANGED PATH, repo-relative and forward-slashed, as the
// vendor reports it. Case-insensitive throughout: `Jenkinsfile`, `JenkinsFile`
// and `jenkinsfile` are the same hazard, and case is the cheapest possible
// bypass of a security control. ONE deliberate exception, documented where it
// lives: AUTH_SOURCE_CAMEL_PATTERN, whose required uppercase boundary is the
// only thing telling `AuthService.ts` from `author.js`.
//
// A rule's `pattern` may be a single regex or an ARRAY of them, matched with
// `some` — an alternative exists only because two anchorings cannot share one
// `i` flag, never to make a rule harder to read.
const SENSITIVE_PATH_RULES = [
  {
    rule: "terraform",
    why: "Terraform configuration, variables or state",
    pattern: /(^|\/)[^/]*\.(tf|tfvars|tfstate|tfstate\.backup)$|\.(tf|tfvars)\.json$/i
  },
  {
    rule: "azure-bicep-arm",
    why: "Azure Bicep or ARM deployment template",
    pattern: /\.bicep(param)?$|(^|\/)(arm|arm-templates?)\/|(^|\/)(azuredeploy|maintemplate|template)[^/]*\.json$/i
  },
  {
    rule: "cloudformation",
    why: "CloudFormation / SAM template",
    pattern: /(^|\/)(cloudformation|cfn)([/._-])|\.(template|cfn)\.(ya?ml|json)$|(^|\/)(template|samconfig)\.ya?ml$/i
  },
  {
    rule: "kubernetes-rbac",
    why: "Kubernetes RBAC or network-policy manifest (by filename)",
    pattern: /(^|\/)rbac\/|(^|\/)(rbac|roles?|rolebindings?|clusterroles?|clusterrolebindings?|networkpolic(y|ies)|netpol|podsecuritypolic(y|ies)|psp)([._-][^/]*)?\.(ya?ml|json)$/i
  },
  {
    rule: "ci-cd",
    why: "CI/CD pipeline definition — it runs with the fleet's credentials",
    pattern: /(^|\/)\.github\/(workflows|actions)\/|(^|\/)\.gitlab-ci[^/]*\.ya?ml$|(^|\/)azure-pipelines[^/]*\.ya?ml$|(^|\/)Jenkinsfile[^/]*$|(^|\/)\.circleci\/|(^|\/)\.buildkite\/|(^|\/)bitbucket-pipelines\.ya?ml$/i
  },
  {
    rule: "secret-material",
    why: "key, certificate, dotenv or a path named for a secret",
    // `.env` matches `.env`, `.env.local`, `.env-prod` — the separator is
    // required so `.environment.md` does not trip it — plus `.envrc`, which is
    // where direnv keeps service-principal credentials.
    //
    // The `(secret|credential|...)` alternative is anchored at `$`, so it only
    // ever read the FINAL BASENAME: `secrets/prod/config.yaml` was classified
    // by its innocent leaf name while a whole directory of key material sat in
    // the path. The `(secrets?|credentials?|creds)` alternative below is
    // segment-anchored the same way auth-source is, so it fires on the
    // DIRECTORY anywhere in the path — and on `creds.json` as a basename.
    pattern: /\.(pem|key|p12|pfx|jks|keystore|asc|gpg|ppk)$|(^|\/)\.env($|[._-])|(^|\/)\.envrc$|(^|\/)(secrets?|credentials?|creds)([._-][^/]*)?(\/|$)|(^|\/)[^/]*(secret|credential|password|passwd|htpasswd|api[-_]?key)[^/]*$|(^|\/)(id_rsa|id_dsa|id_ecdsa|id_ed25519|authorized_keys|\.netrc|\.npmrc|\.pgpass|kubeconfig)([._-][^/]*)?$/i
  },
  {
    rule: "auth-source",
    // CONSERVATIVE BY CHOICE, and the choice is the ANCHORING, not the
    // vocabulary. A term counts only when it is a whole path SEGMENT, the start
    // of one up to a `.`/`_`/`-`, or the leading CamelCase component of one. So
    // `auth/`, `auth.ts`, `authz_test.go` and `AuthService.ts` trip it while
    // `author.js`, `authoring/` and `authority.ts` do not. A substring match on
    // the same words would escalate every file with "session" or "login"
    // anywhere in its path, and a control that fires on everything gets turned
    // off. Known and accepted false positive: docs named `token_*`.
    //
    // The VOCABULARY, by contrast, is widened freely — see AUTH_SOURCE_TERMS.
    // Both patterns are non-global, as every pattern in this list must be.
    why: "authentication / authorization / identity source path",
    pattern: [AUTH_SOURCE_SEGMENT_PATTERN, AUTH_SOURCE_CAMEL_PATTERN]
  }
];

// Matched against the COLLECTED REVIEW CONTENT, because some hazards are
// invisible in a filename: `deploy/manifest.yaml` is a ClusterRoleBinding only
// on the inside. `paths` narrows a rule to the files it can meaningfully apply
// to; `paths: null` means "anywhere in the diff".
const SENSITIVE_CONTENT_RULES = [
  {
    rule: "kubernetes-rbac",
    why: "a manifest declaring a Kubernetes RBAC or network-policy object",
    paths: /\.(ya?ml|json|tpl)$/i,
    // Leading `+`/`-` allowed: in a unified diff the manifest line is prefixed.
    pattern: /^[+\-\s]*["']?kind["']?\s*:\s*["']?(Role|ClusterRole|RoleBinding|ClusterRoleBinding|NetworkPolicy|PodSecurityPolicy|ServiceAccount|Secret)["']?,?\s*$/m
  },
  {
    rule: "azure-bicep-arm",
    why: "an ARM deployment-template schema",
    paths: /\.json$/i,
    pattern: /deploymentTemplate\.json#|Microsoft\.Authorization\/roleAssignments/i
  },
  {
    rule: "cloudformation",
    why: "a CloudFormation / SAM template header",
    paths: /\.(ya?ml|json)$/i,
    pattern: /AWSTemplateFormatVersion|AWS::Serverless-2016-10-31|AWS::IAM::/
  },
  {
    rule: "helm-secret-values",
    why: "a Helm values file carrying a secret-shaped key",
    paths: /(^|\/)values[^/]*\.ya?ml$/i,
    pattern: /^[+\-\s]*["']?[A-Za-z0-9_.-]*(secret|password|passwd|token|api[-_]?key|apikey|credential|privatekey|connectionstring)[A-Za-z0-9_.-]*["']?\s*:/im
  },
  {
    rule: "credential-material",
    why: "credential material inlined in the diff",
    paths: null,
    pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}/
  }
];

// `git diff --name-only` and `git status --short` C-QUOTE any path that is not
// plain ASCII when core.quotePath is on, which is the DEFAULT: `infra/prodü.tf`
// arrives as the literal `"infra/prod\303\274.tf"`, quotes included. Every
// path rule is `^`/`$`-anchored, so against that string a Terraform change
// simply does not match and the whole diff runs unescalated. Decode byte-wise
// and only then to UTF-8 — the octal escapes are UTF-8 BYTES, so decoding them
// one character at a time produces mojibake that matches nothing either.
function unquoteGitPath(filePath) {
  const raw = String(filePath);
  if (raw.length < 2 || !raw.startsWith('"') || !raw.endsWith('"')) {
    return raw;
  }
  const body = raw.slice(1, -1);
  const simple = { n: 0x0a, t: 0x09, r: 0x0d, f: 0x0c, b: 0x08, v: 0x0b, a: 0x07, '"': 0x22, "\\": 0x5c };
  const bytes = [];
  for (let i = 0; i < body.length; i += 1) {
    const ch = body[i];
    if (ch !== "\\") {
      bytes.push(...Buffer.from(ch, "utf8"));
      continue;
    }
    const octal = /^[0-7]{3}/.exec(body.slice(i + 1, i + 4));
    if (octal) {
      bytes.push(parseInt(octal[0], 8));
      i += 3;
      continue;
    }
    const next = body[i + 1];
    if (next !== undefined && Object.prototype.hasOwnProperty.call(simple, next)) {
      bytes.push(simple[next]);
      i += 1;
      continue;
    }
    // Unknown escape: keep the backslash rather than swallow it. Dropping a
    // character can only shorten a path towards matching nothing.
    bytes.push(0x5c);
  }
  return Buffer.from(bytes).toString("utf8");
}

// The PRE-RENAME paths, recovered from the diff body.
//
// `git diff --name-only` — the vendor's only source for `changedFiles`
// (lib/git.mjs:266) — reports a rename as its DESTINATION ALONE. Renaming
// `infra/main.tf` to `archive/main.txt` therefore handed this classifier a
// single path matching no rule at all, and a Terraform change ran at the lane
// default. Verified against git 2.43 with the vendor's exact diff flags.
//
// Git's rename detection is on by default (`diff.renames`, since 2.9), so the
// old name survives in exactly one place: the extended headers `rename from` /
// `copy from`, which the gate already has in hand because it forces
// `includeDiff`. Nothing extra is executed — no second git invocation, no new
// vendor symbol to depend on. When detection is OFF the rename is emitted as a
// delete plus an add and BOTH names are already in `changedFiles`, so the two
// configurations cover each other.
//
// Only the extended headers are read, never the `a/` side of `diff --git a/X
// b/Y`: that split is ambiguous for any path containing " b/" (the hazard
// segmentReviewContent documents below) and a mis-split would invent a path
// that never existed. Extended-header lines sit at column 0 while every line of
// hunk CONTENT carries a `+`, `-` or space prefix, so `^rename from ` cannot
// match a diff's own text. It CAN match a line of an untracked file the
// collector inlined raw — accepted, because that direction only ever WIDENS the
// check, which is the safe direction for this control.
//
// When the body could not be read this returns nothing and the old path is
// genuinely unrecoverable — a hole that is already closed one level up, where
// `diffBodyMissing` escalates unconditionally rather than trusting path rules.
function collectRenamedPaths(content) {
  const paths = new Set();
  for (const line of String(content ?? "").split(/\r?\n/)) {
    const header = /^(?:rename|copy) (?:from|to) (.+)$/.exec(line);
    if (header) {
      paths.add(unquoteGitPath(header[1]));
    }
  }
  return [...paths];
}

// Split the collected content into per-path chunks so a content hit can be
// ATTRIBUTED. Two markers, both the vendor's own: `diff --git a/x b/x` for
// tracked changes and the `### <path>` heading the collector writes above each
// inlined untracked file (lib/git.mjs:196).
//
// Neither marker is trustworthy on its own. A path containing the literal
// " b/" splits the diff header at the wrong place, and `### ` is BOTH the
// collector's untracked-file heading and a perfectly ordinary YAML comment —
// an untracked `deploy/manifest.yaml` whose first line is `### RBAC` yields the
// "path" `RBAC`. That is not cosmetic: `paths` filters on the attributed name,
// so a bogus name makes `RBAC` fail the rule's `\.(ya?ml|json|tpl)$` filter and
// the ClusterRoleBinding below it goes UNCHECKED. A wrong name therefore
// narrows the check, which is why a captured path is honoured only when it is
// a file this diff actually changed; anything else stays `null`. Text before
// the first marker belongs to no path, and a segment with no path is tested
// against EVERY content rule, because not knowing which file the bytes came
// from must widen the check, never narrow it.
function segmentReviewContent(content, changedFiles = []) {
  const known = new Set();
  for (const file of changedFiles ?? []) {
    known.add(String(file));
    known.add(unquoteGitPath(file));
  }
  const attribute = (captured) => (known.has(captured) ? captured : null);

  const segments = [];
  let current = { path: null, lines: [] };
  for (const line of String(content ?? "").split(/\r?\n/)) {
    const diffHeader = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
    const heading = diffHeader ? null : /^### (.+)$/.exec(line);
    if (diffHeader || heading) {
      if (current.lines.length > 0) {
        segments.push(current);
      }
      current = { path: attribute(diffHeader ? diffHeader[2] : heading[1]), lines: [] };
      continue;
    }
    current.lines.push(line);
  }
  if (current.lines.length > 0) {
    segments.push(current);
  }
  return segments.map((segment) => ({ path: segment.path, text: segment.lines.join("\n") }));
}

// Returns one entry per RULE that matched, each naming the paths that matched
// it. Never throws: a classifier that can crash is a classifier that can be
// crashed into silence.
function classifySensitiveChanges(changedFiles, content) {
  const hits = new Map();
  const record = (rule, why, where) => {
    const entry = hits.get(rule) ?? { rule, why, paths: new Set() };
    entry.paths.add(where);
    hits.set(rule, entry);
  };

  // The DECODED path is the real one, and it is what the rules and the stderr
  // line both use — a quoted `"infra/prod\303\274.tf"` matches no anchored
  // pattern and reads as nonsense beside a hit.
  const candidates = changedFiles.map((file) => {
    const filePath = unquoteGitPath(file);
    return { filePath, label: filePath };
  });
  // Both sides of a rename get classified. The old name is LABELLED as such:
  // reporting it bare would send whoever reads the escalation looking for a
  // path this diff no longer contains. `rename to` names a file that is already
  // in changedFiles, so it drops out here and is reported plainly above.
  const known = new Set(candidates.map((candidate) => candidate.filePath));
  for (const renamed of collectRenamedPaths(content)) {
    if (known.has(renamed)) {
      continue;
    }
    known.add(renamed);
    candidates.push({ filePath: renamed, label: `${renamed} (pre-rename path)` });
  }

  for (const { filePath, label } of candidates) {
    for (const { rule, why, pattern } of SENSITIVE_PATH_RULES) {
      const patterns = Array.isArray(pattern) ? pattern : [pattern];
      if (patterns.some((candidate) => candidate.test(filePath))) {
        record(rule, why, label);
      }
    }
  }

  for (const segment of segmentReviewContent(content, changedFiles)) {
    for (const { rule, why, paths, pattern } of SENSITIVE_CONTENT_RULES) {
      if (segment.path !== null && paths && !paths.test(segment.path)) {
        continue;
      }
      if (pattern.test(segment.text)) {
        record(rule, why, segment.path ?? "(unattributed diff content)");
      }
    }
  }

  return [...hits.values()].map((entry) => ({
    rule: entry.rule,
    why: entry.why,
    paths: [...entry.paths].sort()
  }));
}

function describeHitPaths(paths) {
  if (paths.length <= SENSITIVITY_PATHS_SHOWN) {
    return paths.join(", ");
  }
  const shown = paths.slice(0, SENSITIVITY_PATHS_SHOWN).join(", ");
  return `${shown}, +${paths.length - SENSITIVITY_PATHS_SHOWN} more`;
}

// Decide the effort this review will actually run at.
//
// RAISE ONLY. The caller's effort is the floor's floor: if it already meets or
// exceeds SENSITIVITY_FLOOR_EFFORT the gate changes nothing, and the gate never
// lowers anything under any condition. When it does raise, it says so on
// stderr and names the paths — a silent escalation is as bad as a silent
// non-escalation, because neither leaves the caller able to tell what ran.
//
// FAILS CLOSED. If the changed-file list cannot be obtained the diff cannot be
// proven harmless, so it is treated as sensitive. The collector is called
// inside a try: an exception here must not change how a collector failure is
// reported, which is downstream, inside runTrackedJob, where it lands in the
// job record instead of killing the dispatch before a record exists.
//
// ⚠️ This collects the review context a SECOND time (executeAdversarialReviewRun
// collects its own, in the worker process for a --background dispatch). That is
// deliberate: the alternative is serializing a whole diff through the job file,
// which would write reviewed source into records the archive keeps past the
// vendor's session cleanup. The duplicate cost is a local git read against the
// SAME resolved target — there is still exactly one base-ref resolution — set
// against a Codex turn measured in minutes.
function resolveEffectiveEffort(vendor, { cwd, target, requestedEffort }) {
  const unchanged = { effort: requestedEffort, escalated: false, hits: [] };

  // ⚠️ `{ includeDiff: true }` IS THE CONTROL. Left off, the vendor decides for
  // itself (lib/git.mjs:332): it inlines the diff body only when the change is
  // at most `maxInlineFiles` files AND at most `maxInlineDiffBytes` — which
  // default to 2 and 256 KB (git.mjs:8-9). Above either, `inputMode` flips to
  // "self-collect" and `content` is Commit Log + Diff Stat + Changed Files with
  // NO DIFF IN IT, so every SENSITIVE_CONTENT_RULE — the `kind:` check that is
  // the only thing catching an RBAC manifest under an innocent filename — tests
  // an empty haystack and finds nothing. On a 3-file PR. The classifier must
  // never be handed the summary; it asks for the body explicitly.
  //
  // THE BOUND IS THE VENDOR'S AND IT FAILS CLOSED. Forcing the body means a
  // very large diff is read into memory, but the vendor's git helper inherits
  // spawnSync's 1 MiB default maxBuffer (process.mjs:10 passes
  // `options.maxBuffer`, undefined here), so an oversized body raises ENOBUFS,
  // runCommandChecked rethrows it, and this catch fires. No bound of our own is
  // added on top: a second, lower ceiling would only mean deciding a second
  // time what to do when it is hit, and there is exactly one right answer —
  // a diff whose body could not be read has NOT been shown to be insensitive.
  // So the retry below re-collects WITHOUT the body purely to recover the
  // changed-file list (path rules still work, and the operator gets real file
  // names), and `diffBodyMissing` forces an escalation regardless of what those
  // path rules say.
  let context = null;
  let diffBodyMissing = false;
  try {
    context = vendor.collectReviewContext(cwd, target, { includeDiff: true });
  } catch {
    context = null;
  }
  if (context === null) {
    diffBodyMissing = true;
    try {
      context = vendor.collectReviewContext(cwd, target);
    } catch {
      context = null;
    }
  }
  // Belt and braces for the day upstream stops honouring `includeDiff`: a
  // context that SAYS it carries no diff is treated as one that carries no
  // diff. Only an explicit non-inline value counts — an absent `inputMode` is
  // a shape we cannot read, not a summary we can prove.
  if (typeof context?.inputMode === "string" && context.inputMode !== "inline-diff") {
    diffBodyMissing = true;
  }

  const changedFiles = Array.isArray(context?.changedFiles) ? context.changedFiles : null;
  const fileCount = typeof context?.fileCount === "number" ? context.fileCount : changedFiles?.length ?? null;

  // Nothing to review. executeAdversarialReviewRun refuses this outright a
  // moment later; escalating first would print an alarming line about a diff
  // that does not exist.
  if (fileCount === 0) {
    return unchanged;
  }

  let hits;
  if (changedFiles === null || changedFiles.length === 0) {
    hits = [
      {
        rule: "unclassifiable-diff",
        why: "the changed-file list could not be read, so the diff cannot be shown to be insensitive",
        paths: ["(changed-file list unavailable)"]
      }
    ];
  } else {
    hits = classifySensitiveChanges(changedFiles, diffBodyMissing ? null : context?.content);
    if (diffBodyMissing) {
      // Path rules ran and may have found nothing; that is not an acquittal,
      // because the content rules never got to run at all.
      hits.push({
        rule: "unreadable-diff-body",
        why: "the diff body could not be read, so nothing inside the changed files was classified",
        paths: ["(diff body unavailable)"]
      });
    }
  }

  if (hits.length === 0) {
    return unchanged;
  }

  const requestedRank = VALID_REASONING_EFFORTS.indexOf(requestedEffort);
  const floorRank = VALID_REASONING_EFFORTS.indexOf(SENSITIVITY_FLOOR_EFFORT);
  const hitLines = hits.map((hit) => `  ${hit.rule}: ${describeHitPaths(hit.paths)} (${hit.why})`);

  if (requestedRank >= floorRank) {
    // Already at or above the floor: report, change nothing. Saying nothing
    // here would leave the caller unable to tell an unclassified review from a
    // classified one that needed no help.
    errorLines([
      `sensitivity gate: this diff is sensitive, and --effort ${requestedEffort} already meets the`,
      `${SENSITIVITY_FLOOR_EFFORT} floor — leaving it unchanged. Matched:`,
      ...hitLines
    ]);
    return { effort: requestedEffort, escalated: false, hits };
  }

  // The escape hatch is deliberately EXPENSIVE to use: it demands a written
  // reason, prints a warning that is impossible to miss, and the reason is
  // echoed back so it lands in whatever captured this dispatch's stderr. An
  // env var set to "1" would be a switch someone flips once in a shell profile
  // and forgets; a reason string is a decision someone has to make each time.
  const override = String(process.env[SENSITIVITY_OVERRIDE_ENV] ?? "").trim();
  if (override !== "") {
    errorLines([
      `⚠️ SENSITIVITY GATE OVERRIDDEN — this review of a SENSITIVE diff will run at`,
      `--effort ${requestedEffort}, below the ${SENSITIVITY_FLOOR_EFFORT} floor, because`,
      `${SENSITIVITY_OVERRIDE_ENV} is set. Matched:`,
      ...hitLines,
      `stated reason: ${override}`,
      `the finding set from this review is NOT what the ${SENSITIVITY_FLOOR_EFFORT} floor promises;`,
      `do not cite it as an adversarial pass over these paths.`
    ]);
    return { effort: requestedEffort, escalated: false, overridden: true, hits };
  }
  if (process.env[SENSITIVITY_OVERRIDE_ENV] !== undefined) {
    errorLines([
      `${SENSITIVITY_OVERRIDE_ENV} is set but empty — it needs a written reason to take effect.`,
      `Ignoring it and applying the gate.`
    ]);
  }

  // ⚠️ The wording of the first line is a CONTRACT: bin/crew-codex greps
  // `sensitivity gate: raising --effort <from> -> <to>` out of this dispatch's
  // stderr to stamp effortEffective into the .dispatch.json audit record, which
  // otherwise only ever sees argv. Change the phrasing there and here together.
  errorLines([
    `sensitivity gate: raising --effort ${requestedEffort} -> ${SENSITIVITY_FLOOR_EFFORT}. Matched:`,
    ...hitLines,
    `this is a code-enforced floor on adversarial reviews of sensitive changes; the caller's`,
    `effort is only ever raised by it, never lowered. To review at ${requestedEffort} anyway, set`,
    `${SENSITIVITY_OVERRIDE_ENV}="<why>" — it warns loudly and states your reason on stderr.`
  ]);
  return { effort: SENSITIVITY_FLOOR_EFFORT, escalated: true, hits };
}

// Byte-for-byte the composition of executeReviewRun's adversarial branch
// (codex-companion.mjs:405-460), with ONE addition: `effort` on the
// runAppServerTurn call. Keep the payload shape identical — renderStoredJobResult
// and `crew-codex await`'s archiver both read it.
async function executeAdversarialReviewRun(vendor, request) {
  const target = vendor.resolveReviewTarget(request.cwd, {
    base: request.base,
    scope: request.scope
  });
  const focusText = request.focusText?.trim() ?? "";
  const context = vendor.collectReviewContext(request.cwd, target);

  // Same five variables the vendor passes (buildAdversarialReviewPrompt,
  // companion:241). The shipped template references only four of them —
  // REVIEW_KIND is unused today — but pass all five so a template that starts
  // using it renders the same here as it does on the vendor path.
  // SEMANTIC contract check, not just a presence check.
  //
  // The import guard above proves each vendor symbol EXISTS and is callable.
  // It cannot prove `collectReviewContext` still returns the field names we
  // read. If upstream renames `content` or `collectionGuidance`, every import
  // succeeds, `REVIEW_INPUT` interpolates to the empty string, and the model is
  // handed a review prompt containing NO DIFF.
  //
  // That failure does not look like a failure. An adversarial review with
  // nothing to review returns "no findings" -- which renders as a CLEAN PASS
  // and silently approves the change. A review gate that approves on breakage
  // is worse than one that errors, so this refuses to dispatch instead.
  //
  // Deliberately checked here rather than in the import guard: `content` is
  // legitimately empty only when there is genuinely no diff, which is itself
  // not something worth spending a Codex turn on.
  // NOT sufficient on its own: the vendor renders an empty section as the
  // literal string "(none)" (lib/git.mjs:194), so `content` stays non-empty for
  // a target with ZERO changed files. A clean working tree, or --base HEAD,
  // would sail past a non-empty-string check and dispatch a review of nothing —
  // which answers "no findings" and renders as a CLEAN PASS. Check the
  // semantic invariant too, not just the string.
  const changed = Array.isArray(context.changedFiles) ? context.changedFiles.length : null;
  const fileCount = typeof context.fileCount === "number" ? context.fileCount : changed;
  // fileCount is authoritative and changedFiles is only a FALLBACK source for
  // it — the vendor derives one from the other (`fileCount: details.changedFiles
  // .length`), so they are never independent signals. ORing them would make an
  // internally inconsistent context throw for the wrong reason.
  if (fileCount === 0) {
    throw new Error(
      `${context.target.label} has no changed files — refusing to dispatch an adversarial ` +
        `review of an empty diff. It would return "no findings", which is indistinguishable ` +
        `from a clean review of real changes. Check the base ref and that the branch has commits.`
    );
  }
  if (fileCount === null) {
    throw new Error(
      `collectReviewContext() returned neither "fileCount" nor "changedFiles" for ` +
        `${context.target.label}. codex@openai-codex ${request.pluginVersion} may have renamed ` +
        `them; refusing to dispatch, because without them an empty diff cannot be told from a ` +
        `real one and an empty review renders as a clean pass.`
    );
  }

  // fileCount proves a filename EXISTS, not that we have anything to review.
  // The vendor renders unusable changed files as `(skipped: ...)` markers
  // (lib/git.mjs:203-219) -- too large, binary, directory, broken symlink. A
  // working tree holding one untracked text file over the untracked-byte limit
  // yields fileCount 1, diffBytes 0, inline-diff mode, and content that is
  // nothing but a skip marker. Both the fileCount check above and the
  // non-empty-string check below pass, and the model is asked to adversarially
  // review a list of files it cannot see -- answering "no findings", which
  // renders as a CLEAN PASS. Same silent-approval hazard, one level down.
  const skipped = collectSkippedFiles(context.content, context.changedFiles);
  if (skipped.length > 0 && skipped.length >= fileCount) {
    throw new Error(
      `every changed file in ${context.target.label} was skipped by the collector ` +
        `(${skipped.length} of ${fileCount}: ${skipped.join(", ")}). There is no reviewable ` +
        `content, so a review would return "no findings" indistinguishably from a clean ` +
        `review. Re-run without --effort to use the vendor path, or narrow the target.`
    );
  }
  if (skipped.length > 0) {
    // Partial skips are legitimate (one binary among ten files), but the
    // reviewer must be told rather than silently shown less than it thinks.
    context.collectionGuidance =
      `${context.collectionGuidance}\n\n⚠️ ${skipped.length} of ${fileCount} changed file(s) ` +
      `were NOT inlined by the collector: ${skipped.join(", ")}. ` +
      `Read them directly before concluding anything about them.`;
  }

  for (const [field, value] of [
    ["content", context.content],
    ["collectionGuidance", context.collectionGuidance]
  ]) {
    if (typeof value !== "string" || value.trim() === "") {
      // Thrown, never process.exit(): this runs inside runTrackedJob's runner,
      // so throwing lets it mark the job failed and write the reason to the job
      // log. An exit() here would leave the record stuck at `running` -- the
      // STALE signature `crew-codex await` reports as exit 3.
      throw new Error(
        `collectReviewContext() returned no usable "${field}" for ${context.target.label}. ` +
          `Either this target has no changes to review, or codex@openai-codex ${request.pluginVersion} ` +
          `renamed that field. Refusing to dispatch: a review prompt with an empty REVIEW_INPUT ` +
          `returns "no findings", which is indistinguishable from a clean review. ` +
          `Check the diff is non-empty, then re-run without --effort to compare against the vendor path.`
      );
    }
  }

  const prompt = vendor.interpolateTemplate(
    vendor.loadPromptTemplate(request.pluginRoot, "adversarial-review"),
    {
      REVIEW_KIND: REVIEW_NAME,
      TARGET_LABEL: context.target.label,
      USER_FOCUS: focusText || "No extra focus provided.",
      REVIEW_COLLECTION_GUIDANCE: context.collectionGuidance,
      REVIEW_INPUT: context.content
    }
  );

  const result = await vendor.runAppServerTurn(context.repoRoot, {
    prompt,
    // Raw, NOT alias-normalized: the companion normalizes `spark` only on the
    // task path (handleTask, :773); handleReviewCommand forwards options.model
    // untouched (:748). Matching that keeps the two paths interchangeable.
    model: request.model,
    sandbox: "read-only",
    outputSchema: vendor.readOutputSchema(
      path.join(request.pluginRoot, "schemas", "review-output.schema.json")
    ),
    // THE POINT OF THIS FILE. lib/codex.mjs:1140 forwards this straight to
    // turn/start; the vendor review path leaves it null.
    effort: request.effort,
    onProgress: request.onProgress
  });

  const parsed = vendor.parseStructuredOutput(result.finalMessage, {
    status: result.status,
    failureMessage: result.error?.message ?? result.stderr
  });

  const payload = {
    review: REVIEW_NAME,
    target,
    threadId: result.threadId,
    context: {
      repoRoot: context.repoRoot,
      branch: context.branch,
      summary: context.summary
    },
    codex: {
      status: result.status,
      stderr: result.stderr,
      stdout: result.finalMessage,
      reasoning: result.reasoningSummary
    },
    result: parsed.parsed,
    rawOutput: parsed.rawOutput,
    parseError: parsed.parseError,
    reasoningSummary: result.reasoningSummary,
    // Additive: the vendor payload records nothing about how the turn was
    // configured, so a finished review cannot be audited after the fact.
    dispatch: {
      driver: "codex-crew/lib/review-with-effort.mjs",
      effort: request.effort,
      model: request.model ?? null,
      codexPluginVersion: request.pluginVersion
    }
  };

  return {
    exitStatus: result.status,
    threadId: result.threadId,
    turnId: result.turnId,
    payload,
    rendered: vendor.renderReviewResult(parsed, {
      reviewLabel: REVIEW_NAME,
      targetLabel: context.target.label,
      reasoningSummary: result.reasoningSummary
    }),
    summary:
      parsed.parsed?.summary ??
      parsed.parseError ??
      firstMeaningfulLine(result.finalMessage, `${REVIEW_NAME} finished.`),
    jobTitle: JOB_TITLE,
    jobClass: "review",
    targetLabel: context.target.label
  };
}

// Mirrors createCompanionJob (companion:567) for kind == "adversarial-review",
// so status/result/cancel classify these jobs exactly as vendor ones.
function buildJobRecord(vendor, { workspaceRoot, targetLabel, effort, effortRequested, model, pluginVersion }) {
  return vendor.createJobRecord({
    id: vendor.generateJobId("review"),
    kind: "adversarial-review",
    kindLabel: "adversarial-review",
    title: JOB_TITLE,
    workspaceRoot,
    jobClass: "review",
    summary: `${REVIEW_NAME} ${targetLabel}`,
    // Additive fields, and the reason this driver stamps rather than just
    // dispatches: companion-written REVIEW records carry neither model nor
    // effort (task records carry both under storedJob.request), and review
    // effort came from the codex config, which no record ever saw. With the
    // effort now chosen per dispatch, the record is the only place it can be
    // recovered from later.
    effort,
    // Both halves, always, even when they agree: a record that carries only the
    // effective effort cannot answer "was this raised?" after the fact, and the
    // sensitivity gate is exactly the thing an auditor comes back to check.
    // Both names are already in the archive sanitizer's request/metadata
    // allowlists (bin/crew-codex), so they survive archiving verbatim.
    effortRequested,
    effortEffective: effort,
    model: model ?? null,
    codexPluginVersion: pluginVersion,
    dispatchedBy: "codex-crew/review-with-effort"
  });
}

// The stderr line the gate prints is seen by whoever launched the dispatch; the
// job log is what survives to be read later, and for a --background review it is
// the only record a human ever gets (the worker's stdio is "ignore").
function appendSensitivityLogLine(vendor, logFile, request) {
  if (!request.effortRequested || request.effortRequested === request.effort) {
    return;
  }
  vendor.appendLogLine(
    logFile,
    `Sensitivity gate raised the reasoning effort from ${request.effortRequested} to ` +
      `${request.effort}: the diff matched ${request.sensitivityRules?.join(", ") || "a sensitive path rule"}.`
  );
}

function outputResult(value, asJson) {
  if (asJson) {
    console.log(JSON.stringify(value, null, 2));
  } else {
    process.stdout.write(value);
  }
}

async function runForeground(vendor, job, request, asJson) {
  const logFile = vendor.createJobLogFile(job.workspaceRoot, job.id, job.title);
  vendor.appendLogLine(
    logFile,
    `Reasoning effort ${request.effort} requested via crew-codex (codex@openai-codex ${request.pluginVersion}).`
  );
  appendSensitivityLogLine(vendor, logFile, request);
  const progress = vendor.createProgressReporter({
    stderr: !asJson,
    logFile,
    onEvent: vendor.createJobProgressUpdater(job.workspaceRoot, job.id)
  });

  // stderr even under --json: stdout must stay pure JSON, but crew-codex's
  // dispatch stamper scrapes the job id from either stream, and a foreground
  // review otherwise announces no id at all (the vendor path has the same
  // gap, which is why foreground reviews go unstamped today).
  process.stderr.write(`[codex] ${JOB_TITLE} ${job.id} starting at effort ${request.effort}.\n`);

  const execution = await vendor.runTrackedJob(
    job,
    () => executeAdversarialReviewRun(vendor, { ...request, onProgress: progress }),
    { logFile }
  );

  outputResult(asJson ? execution.payload : execution.rendered, asJson);
  if (execution.exitStatus !== 0) {
    process.exitCode = execution.exitStatus;
  }
}

// Mirrors enqueueBackgroundTask + spawnDetachedTaskWorker (companion:684/670).
//
// Backgrounding is not cosmetic here. The vendor's adversarial-review runs
// FOREGROUND with buffered output, so a plain Bash call to it dies at the
// 120s default tool timeout while the codex job keeps running — the review is
// then orphaned and shows up later as a STALE record. Detaching (detached +
// stdio ignore + unref) returns a job id immediately and lets
// `crew-codex await` block on the job's own process instead.
function enqueueBackground(vendor, job, request) {
  const logFile = vendor.createJobLogFile(job.workspaceRoot, job.id, job.title);
  vendor.appendLogLine(logFile, "Queued for background execution.");
  vendor.appendLogLine(
    logFile,
    `Reasoning effort ${request.effort} requested via crew-codex (codex@openai-codex ${request.pluginVersion}).`
  );
  appendSensitivityLogLine(vendor, logFile, request);

  // Record BEFORE spawn, unlike the vendor, which spawns first and then writes
  // the record the child immediately reads back. Writing first removes that
  // race outright. The cost is that `pid` stays null until the child's own
  // runTrackedJob stamps it (the same pid the vendor would have recorded), and
  // for that ~100ms window the job is `queued`, which every consumer already
  // handles without a pid.
  const queuedRecord = {
    ...job,
    status: "queued",
    phase: "queued",
    pid: null,
    logFile,
    request
  };
  const jobFile = vendor.writeJobFile(job.workspaceRoot, job.id, queuedRecord);
  vendor.upsertJob(job.workspaceRoot, queuedRecord);

  // --job-file rather than re-deriving the path: resolveJobFile is another
  // vendor symbol to depend on, and writeJobFile already handed us the path.
  const child = spawn(
    process.execPath,
    [
      SELF_PATH,
      "--worker",
      "--job-id",
      job.id,
      "--job-file",
      jobFile,
      "--plugin-root",
      request.pluginRoot,
      "--plugin-version",
      request.pluginVersion
    ],
    {
      cwd: request.cwd,
      env: process.env,
      detached: true,
      stdio: "ignore",
      windowsHide: true
    }
  );
  child.unref();

  return {
    jobId: job.id,
    status: "queued",
    title: job.title,
    summary: job.summary,
    logFile,
    effort: request.effort,
    model: request.model ?? null,
    codexPluginVersion: request.pluginVersion
  };
}

// Mirrors handleTaskWorker (companion:841): re-read the stored record so the
// running/completed record keeps the queued record's fields (createdAt,
// sessionId, effort, request) instead of a freshly minted approximation.
async function runWorker(vendor, options) {
  const jobFile = options["job-file"];
  if (!jobFile) {
    usageFailure("--worker requires --job-file (written by the parent dispatch).");
  }

  let storedJob;
  try {
    storedJob = JSON.parse(fs.readFileSync(jobFile, "utf8"));
  } catch (error) {
    errorLines([`worker could not read job record ${jobFile}: ${error.message}`]);
    process.exit(1);
  }

  const request = storedJob.request;
  if (!request || typeof request !== "object") {
    errorLines([`stored job ${storedJob.id} is missing its review request payload.`]);
    process.exit(1);
  }

  const logFile = storedJob.logFile ?? vendor.createJobLogFile(storedJob.workspaceRoot, storedJob.id, storedJob.title);
  const progress = vendor.createProgressReporter({
    stderr: false,
    logFile,
    onEvent: vendor.createJobProgressUpdater(storedJob.workspaceRoot, storedJob.id)
  });

  try {
    await vendor.runTrackedJob(
      { ...storedJob, logFile },
      () => executeAdversarialReviewRun(vendor, { ...request, onProgress: progress }),
      { logFile }
    );
  } catch {
    // runTrackedJob already wrote the failure into the job record and log;
    // stdio is "ignore" for a detached worker, so there is nowhere to report.
    process.exitCode = 1;
  }
}

async function main() {
  const { options, positionals } = parseArgv(process.argv.slice(2));

  const pluginRoot = options["plugin-root"];
  if (!pluginRoot) {
    usageFailure("--plugin-root is required (crew-codex resolves it from installed_plugins.json).");
  }
  const pluginVersion = resolvePluginVersion(pluginRoot, options["plugin-version"]);
  const vendor = await loadVendorModules(pluginRoot, pluginVersion);

  if (options.worker) {
    await runWorker(vendor, options);
    return;
  }

  const effort = String(options.effort ?? "").trim().toLowerCase();
  if (!effort) {
    usageFailure("--effort is required; without it crew-codex uses the vendor review path.");
  }
  if (!VALID_REASONING_EFFORTS.includes(effort)) {
    usageFailure(
      `invalid --effort "${options.effort}". Valid values: ${VALID_REASONING_EFFORTS.join("|")}.`
    );
  }

  const requestedModel = options.model ?? null;

  const cwd = options.cwd ? path.resolve(process.cwd(), options.cwd) : process.cwd();
  const workspaceRoot = vendor.resolveWorkspaceRoot(cwd);
  const focusText = positionals.join(" ").trim();

  // Resolved up front for the job summary, exactly as handleReviewCommand does
  // (:729) — a bad --scope/--base must fail before a job record exists.
  const target = vendor.resolveReviewTarget(cwd, { base: options.base, scope: options.scope });

  // The sensitivity gate, applied HERE rather than inside the run: the effort it
  // decides has to be the one written into the request the background worker
  // replays and into the job record's audit fields, and its stderr line has to
  // reach the process the caller is watching — a detached worker's stdio is
  // "ignore", so a line printed there is written to nobody. Same `target`, so
  // the base ref is resolved exactly once.
  const gate = resolveEffectiveEffort(vendor, { cwd, target, requestedEffort: effort });
  const effectiveEffort = gate.effort;

  // Warn, never block. No --model means the codex config picks the model, and
  // that default is a 5.6 model here, so an absent model is treated as 5.6 too
  // — a false warning costs a line of stderr, a missed one costs a whole job.
  //
  // AFTER the gate, and about the EFFECTIVE effort, because the warning ends
  // "expect this job to fail at the API". Printed before the gate it described
  // an effort that was about to be replaced: `--effort none` on a sensitive
  // diff runs at xhigh, which no model rejects, so the prediction was simply
  // wrong — and a warning that cries wolf is one nobody reads.
  const strictFamily = EFFORTS_REJECTED_BY_STRICT_MODELS.has(effectiveEffort)
    ? modelRejectsMinimalEfforts(requestedModel)
    : null;
  if (strictFamily) {
    errorLines([
      `warning: --effort ${effectiveEffort} is rejected by ${strictFamily.label} — the API returns 400 on`,
      `reasoning.effort for "none" and "minimal". ${strictFamily.ladder}`,
      `Dispatching anyway${requestedModel === null ? " (no --model given, so the codex config's default model applies)" : ""};`,
      `expect this job to fail at the API, not here.`
    ]);
  }

  const request = {
    cwd,
    base: options.base ?? null,
    scope: options.scope ?? null,
    model: requestedModel,
    effort: effectiveEffort,
    // What the caller asked for, kept beside what will run. Allowlisted in the
    // archive sanitizer (bin/crew-codex), so the pair survives archiving.
    effortRequested: effort,
    sensitivityRules: gate.hits.map((hit) => hit.rule),
    focusText,
    pluginRoot,
    pluginVersion
  };

  const job = buildJobRecord(vendor, {
    workspaceRoot,
    targetLabel: target.label,
    effort: effectiveEffort,
    effortRequested: effort,
    model: requestedModel,
    pluginVersion
  });

  if (options.background) {
    const payload = enqueueBackground(vendor, job, request);
    outputResult(
      options.json
        ? payload
        : `${payload.title} started in the background as ${payload.jobId} (effort ${effectiveEffort}). Check /codex:status ${payload.jobId} for progress.\n`,
      options.json
    );
    return;
  }

  await runForeground(vendor, job, request, Boolean(options.json));
}

main().catch((error) => {
  errorLines([error instanceof Error ? error.message : String(error)]);
  process.exit(1);
});

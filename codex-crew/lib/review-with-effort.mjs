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
// We still ACCEPT all six — another model family may take them, and pinning
// the wrapper to one family's limits would be wrong — but we warn, because
// otherwise the failure surfaces as an opaque API 400 minutes into a job
// rather than as a predictable consequence of the flag.
const EFFORTS_REJECTED_BY_GPT_5_6 = new Set(["none", "minimal"]);
const GPT_5_6_MODEL_PATTERN = /^gpt-5\.6/i;

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
function buildJobRecord(vendor, { workspaceRoot, targetLabel, effort, model, pluginVersion }) {
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
    model: model ?? null,
    codexPluginVersion: pluginVersion,
    dispatchedBy: "codex-crew/review-with-effort"
  });
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

  // Warn, never block. No --model means the codex config picks the model, and
  // that default is a 5.6 model here, so an absent model is treated as 5.6 too
  // — a false warning costs a line of stderr, a missed one costs a whole job.
  const requestedModel = options.model ?? null;
  if (
    EFFORTS_REJECTED_BY_GPT_5_6.has(effort) &&
    (requestedModel === null || GPT_5_6_MODEL_PATTERN.test(requestedModel))
  ) {
    errorLines([
      `warning: --effort ${effort} is rejected by the GPT-5.6 family — the API returns 400 on`,
      `reasoning.effort for "none" and "minimal". The usable ladder on gpt-5.6-sol/terra/luna is`,
      `low|medium|high|xhigh. Dispatching anyway${requestedModel === null ? " (no --model given, so the codex config's default model applies)" : ""};`,
      `expect this job to fail at the API, not here.`
    ]);
  }

  const cwd = options.cwd ? path.resolve(process.cwd(), options.cwd) : process.cwd();
  const workspaceRoot = vendor.resolveWorkspaceRoot(cwd);
  const focusText = positionals.join(" ").trim();

  // Resolved up front for the job summary, exactly as handleReviewCommand does
  // (:729) — a bad --scope/--base must fail before a job record exists.
  const target = vendor.resolveReviewTarget(cwd, { base: options.base, scope: options.scope });

  const request = {
    cwd,
    base: options.base ?? null,
    scope: options.scope ?? null,
    model: requestedModel,
    effort,
    focusText,
    pluginRoot,
    pluginVersion
  };

  const job = buildJobRecord(vendor, {
    workspaceRoot,
    targetLabel: target.label,
    effort,
    model: requestedModel,
    pluginVersion
  });

  if (options.background) {
    const payload = enqueueBackground(vendor, job, request);
    outputResult(
      options.json
        ? payload
        : `${payload.title} started in the background as ${payload.jobId} (effort ${effort}). Check /codex:status ${payload.jobId} for progress.\n`,
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

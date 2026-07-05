export const meta = {
  name: 'secure-research',
  description: 'Multi-source web research that gathers cited findings and synthesizes a grounded report. Use when the user wants to research, investigate, look into, compare, or "find everything about" a topic. The everyday deep-research default. Privacy-aware: sensitive topics are gated, redacted, and routed through self-hosted SearXNG. Cheaper than secure-deep-research. Reach for that one instead only when claims need per-claim adversarial verification.',
  whenToUse: 'The go-to for broad, cited research. If the question is underspecified (e.g. "what car to buy" with no budget/use-case/region), ask 2-3 clarifying questions first, then pass the refined question as args.',
  phases: [
    {"title":"Scope","detail":"Decompose into complexity-scaled angles + classify privacy sensitivity (no web access — safe before gating)"},
    {"title":"Research","detail":"parallel researcher subagents (retrievers, à la CC's Explore) — each searches, reads, and pulls cited findings in its own context","model":"haiku"},
    {"title":"Gap check","detail":"one pass — is coverage sufficient? emit up to a few follow-up angles (bounded, one extra wave)","model":"sonnet"},
    {"title":"Synthesize","detail":"merge findings, drop anything ungrounded, cite sources, write the report"},
  ],
}

// secure-research: Scope+triage → [gate?] → Research wave (self-contained subagents) → Gap check → [one follow-up wave?] → Synthesize
//
// The third deep-research variant, built to the Anthropic "multi-agent research system" (Claude Research)
// shape rather than the bughunter shape that secure-deep-research inherited:
//   • Orchestrator-worker: the script is the lead agent. Researcher subagents are the workers.
//   • Each researcher owns a CLEAN context and does its OWN search→read→extract (3-8 tool calls, start
//     broad then narrow), returning only distilled cited findings, never raw pages. That context
//     isolation is where the token efficiency comes from.
//   • Fan-out SCALES TO COMPLEXITY (simple→1-2 · moderate→3-5 · complex→6-10 angles), not a fixed 5.
//   • ONE bounded gap-check loop can trigger a single follow-up wave for what the first wave missed.
//     Anthropic's iterative-deepening loop, capped so it can't runaway.
//   • Verification = CITATION GROUNDING at synthesis (every finding must trace to a source, ungrounded
//     ones are dropped), NOT a 3-vote-per-claim adversarial refutation tournament. That tournament was
//     ~77% of secure-deep-research's agent calls (up to 75 of ~97) and over-refuted true claims on
//     cheap models: high cost, unclear quality gain. Grounding gets the attribution benefit for ~1 call.
//
// Token shape vs secure-deep-research (normal run): simple ≈ 3-4 calls, moderate ≈ 6-9, complex ≈ 12-18,
// against secure-deep-research's flat ~97. The saved budget is meant to go into breadth/depth (more
// researchers, the gap wave), which is the lever that actually moves research quality.
//
// Privacy intelligence (carried over intact from secure-deep-research): a fan-out sprays one topic
// across third-party engines many times, so the Scope agent classifies sensitivity (conservatively,
// when in doubt, sensitive), and for sensitive topics the workflow:
//   1. REDACTS: Scope generalizes identifying specifics out of the search queries (full question stays internal).
//   2. GATES: returns the plan for confirmation BEFORE any external query fires (Scope has no web access).
//   3. REDUCES: fewer angles AND the follow-up wave is disabled (hard cap on amplification).
//   4. ROUTES: search + fetch go through self-hosted SearXNG (de-identified vs. upstream engines).
// NOTE: this de-identifies, it does not cloak. Upstream engines still see query text, and the model
// already has the full question. The redaction + reduced amplification do more for privacy than the
// engine swap alone.
//
// Model tiering: the mechanical MIDDLE is pinned cheap. The reasoning-heavy ENDS inherit the session
// model, so a Sonnet/Opus session spends its tier at the beginning and end and Haiku carries the bulk:
//   Scope      → inherit: decomposition + conservative privacy triage runs at the session tier. The
//                "when in doubt, sensitive" rule fails safe regardless of model. One call.
//   Research   → Haiku: the volume tier, and a RETRIEVER, not a judge: search → read → pull cited
//                passages, high-recall, report compactly. This is exactly CC's Explore agent, which runs
//                Haiku in production for bounded agentic retrieval. The retriever/judge split is the whole
//                point: Haiku is unreliable as a last-word VERIFIER/gate (told to "default to refuted" it
//                over-refutes and kills true claims), so the judge role lives OUT of the worker and IN the
//                synthesis (citation grounding). The worker is pure retrieval, where a Haiku mislabel is
//                recoverable at synthesis. Bump to Sonnet via args.researchModel for genuinely
//                adversarial-source / high-stakes topics where retrieval-time judgment matters.
//   Gap check  → Sonnet: a JUDGMENT call (is coverage sufficient, what's missing), not retrieval, and a
//                gate, so it stays pinned to Sonnet regardless of session tier. One call over a compact digest.
//   Synthesize → inherit: the genuinely reasoning-heavy deliverable (merge, ground, calibrate confidence,
//                write the report) runs at the session tier: Opus session → Opus synthesis, Sonnet → Sonnet.
//                Section-map (sharded mode) stays on Sonnet. Only the final assembly inherits.
//
// Invocation:
//   Workflow({name:'secure-research', args:'<question>'})                                  // string form
//   Workflow({name:'secure-research', args:{question:'...', sensitiveConfirmed:true}})     // proceed past the gate
//   Workflow({name:'secure-research', args:{question:'...', mode:'normal'|'sensitive'}})   // force the routing
//   Workflow({name:'secure-research', args:{question:'...', maxAngles:N, secondWave:false}}) // tune fan-out
//   Workflow({name:'secure-research', args:{question:'...', researchModel:'sonnet'}})         // bump the retriever tier
//   Workflow({name:'secure-research', args:{question:'...', breadth:3}})                       // N Haiku researchers/angle (wider recall, cheap)
//   Workflow({name:'secure-research', args:{question:'...', synthesis:'sharded'}})             // map-reduce synthesis (force; auto past SHARD_MIN findings)
//   Workflow({name:'secure-research', args:{question:'...', harvest:true}})                     // skip the LLM reduce, return deduped raw findings (holds up for huge exhaustive runs / DB population)

// Complexity → angle count (Scope proposes; these clamp it). Sensitive clamps tighter to cut amplification.
const ANGLE_CAP = { simple: 2, moderate: 5, complex: 10 }
const SENSITIVE_ANGLE_CAP = 4
const MAX_FOLLOWUP_ANGLES = 4   // follow-up wave is bounded and one-shot
const SHARD_MIN = 60            // auto-shard synthesis above this many gathered findings (single Opus funnel compresses too hard past here)

// ─── Schemas ───
const SCOPE_SCHEMA = {
  type: "object", required: ["question", "summary", "complexity", "angles", "sensitivity"],
  properties: {
    question: { type: "string" },
    summary: { type: "string" },
    complexity: { enum: ["simple", "moderate", "complex"] },
    sensitivity: { enum: ["normal", "sensitive"] },
    sensitivityRationale: { type: "string" },
    redactionNotes: { type: "string" },
    angles: { type: "array", minItems: 1, maxItems: 10, items: {
      type: "object", required: ["label", "query"],
      properties: {
        label: { type: "string" },
        query: { type: "string" },
        rationale: { type: "string" },
      },
    }},
  },
}
// A researcher subagent returns distilled, cited findings, never raw page text.
const BRIEF_SCHEMA = {
  type: "object", required: ["angleLabel", "findings", "coverageNote"],
  properties: {
    angleLabel: { type: "string" },
    coverageNote: { type: "string" },   // what this angle did / did not turn up
    searchesRun: { type: "integer" },   // informational
    findings: { type: "array", maxItems: 8, items: {
      type: "object", required: ["claim", "confidence", "sourceUrl", "quote"],
      properties: {
        claim: { type: "string" },
        confidence: { enum: ["high", "medium", "low"] },
        sourceUrl: { type: "string" },
        sourceTitle: { type: "string" },
        sourceQuality: { enum: ["primary", "secondary", "blog", "forum", "unreliable"] },
        quote: { type: "string" },
        importance: { enum: ["central", "supporting", "tangential"] },
      },
    }},
  },
}
const GAP_SCHEMA = {
  type: "object", required: ["sufficient", "gaps", "followUpAngles"],
  properties: {
    sufficient: { type: "boolean" },
    gaps: { type: "array", items: { type: "string" } },
    followUpAngles: { type: "array", maxItems: 4, items: {
      type: "object", required: ["label", "query"],
      properties: {
        label: { type: "string" },
        query: { type: "string" },
        rationale: { type: "string" },
      },
    }},
  },
}
const REPORT_SCHEMA = {
  type: "object", required: ["summary", "findings", "caveats"],
  properties: {
    summary: { type: "string" },
    findings: { type: "array", items: {
      type: "object", required: ["claim", "confidence", "sources", "evidence"],
      properties: {
        claim: { type: "string" },
        confidence: { enum: ["high", "medium", "low"] },
        sources: { type: "array", items: { type: "string" } },
        evidence: { type: "string" },
      },
    }},
    caveats: { type: "string" },
    openQuestions: { type: "array", items: { type: "string" } },
  },
}
// One section's grounded findings (map step of sharded synthesis).
const SECTION_SCHEMA = {
  type: "object", required: ["findings"],
  properties: {
    findings: { type: "array", items: {
      type: "object", required: ["claim", "confidence", "sources"],
      properties: {
        claim: { type: "string" },
        confidence: { enum: ["high", "medium", "low"] },
        sources: { type: "array", items: { type: "string" } },
        evidence: { type: "string" },
      },
    }},
  },
}

// ─── Parse args ───
let QUESTION = "", sensitiveConfirmed = false, forceMode = null, ovAngles = null, secondWaveOpt = null
let researchModel = "haiku"   // the retriever tier (default Haiku, à la Explore); bump to sonnet for hard/adversarial-source topics
let breadth = 1               // researchers PER angle (default 1); >1 fans out more cheap Haiku retrieval, each with a different lens, for wider recall
let synthesisMode = "auto"    // "auto" | "single" | "sharded": sharded = map-reduce (Sonnet per section → 1 Opus assembly), widens the output funnel
let harvest = false           // harvest mode: skip the LLM reduce, return deduped raw findings (holds up for very large exhaustive runs; no assembly stall)
if (typeof args === "string") {
  QUESTION = args.trim()
} else if (args && typeof args === "object") {
  QUESTION = (args.question || "").trim()
  sensitiveConfirmed = !!args.sensitiveConfirmed
  forceMode = args.mode === "normal" || args.mode === "sensitive" ? args.mode : null
  ovAngles = Number.isFinite(args.maxAngles) ? args.maxAngles : null
  secondWaveOpt = typeof args.secondWave === "boolean" ? args.secondWave : null
  researchModel = ["haiku", "sonnet", "opus"].includes(args.researchModel) ? args.researchModel : "haiku"
  breadth = Number.isFinite(args.breadth) ? Math.max(1, Math.min(6, Math.floor(args.breadth))) : 1
  synthesisMode = ["auto", "single", "sharded"].includes(args.synthesis) ? args.synthesis : "auto"
  harvest = args.harvest === true || args.output === "harvest"
}
if (!QUESTION) {
  return { error: "No research question provided. Pass it as args: Workflow({name: 'secure-research', args: '<question>'}) or args: {question, sensitiveConfirmed, mode, maxAngles, secondWave}." }
}

// ─── Phase 0: Scope: decompose (complexity-scaled) + classify privacy sensitivity ───
// Pure reasoning, NO web access: safe to run before the gate. Nothing leaves the host yet.
phase("Scope")
const scope = await agent(
  "Decompose this research question into complementary research angles, size the effort to its complexity, and classify its privacy sensitivity.\n\n" +
  "## Question\n" + QUESTION + "\n\n" +
  "## Task A — complexity\n" +
  "Rate the question's complexity and let it set how many angles to research:\n" +
  "- **simple** — a single fact / definition / quick lookup → 1-2 angles\n" +
  "- **moderate** — a comparison, a how-does-X-work, a bounded survey → 3-5 angles\n" +
  "- **complex** — a broad landscape, a multi-factor decision, a deep investigation → 6-10 angles\n" +
  "Don't inflate: most questions are simple or moderate. Only go complex when the question genuinely has many independent facets.\n\n" +
  "## Task B — sensitivity triage (be CONSERVATIVE: when in doubt, mark sensitive)\n" +
  "Mark **sensitive** if researching this would spray identifying or private terms across third-party search engines in a way the user likely wouldn't want, e.g.: a named/identifiable private individual; health, medical, legal, or personal-financial specifics tied to a person; sexuality/religion/political affiliation of identifiable people; security vulnerabilities tied to a specific target/host; credentials, account numbers, internal codenames, or business-confidential material. Mark **normal** for general/public/technical topics with no private specifics.\n" +
  "Give a one-line sensitivityRationale.\n\n" +
  "## Task C — angles\n" +
  "Generate distinct research angles (as many as the complexity tier calls for) that together cover the question. Each angle is a self-contained sub-investigation with its own starting search query. Pick angles that suit the domain. Examples:\n" +
  "- broad/primary · academic/technical · recent news · contrarian/skeptical · practitioner/implementation\n" +
  "- For tech: state-of-art · benchmarks · limitations · industry adoption · cost/tradeoffs\n" +
  "Make the starting query broad enough to survey the angle (the researcher will narrow from there). Avoid redundant angles.\n\n" +
  "## Task D — redaction (ONLY if sensitive)\n" +
  "If sensitive, write each starting `query` to GENERALIZE AWAY the most identifying/sensitive specifics while preserving research intent — e.g., abstract a personal name to a role/category, drop exact addresses/account numbers/internal codenames, broaden a target-specific vuln to the general class. The full unredacted question stays internal (for synthesis); only the outgoing queries are redacted. Record what you generalized in redactionNotes. If normal, leave redactionNotes empty and use queries as-is.\n\n" +
  "Return: the question (verbatim or lightly normalized), a 1-2 sentence decomposition strategy (summary), complexity, sensitivity + sensitivityRationale, redactionNotes, and the angles.\n\nStructured output only.",
  { label: "scope", schema: SCOPE_SCHEMA }
)
if (!scope) {
  return { error: "Scope agent returned no result — cannot decompose the research question." }
}

// ─── Resolve sensitivity (forceMode overrides the classifier) + routing/limits ───
const SENSITIVE = forceMode ? forceMode === "sensitive" : scope.sensitivity === "sensitive"
const tools = SENSITIVE
  ? {
      searchHow: "the SearXNG MCP tool `mcp__searxng__searxng_web_search` (self-hosted; load its schema via ToolSearch \"select:mcp__searxng__searxng_web_search\" if needed). Do NOT use WebSearch for this sensitive topic",
      fetchHow: "the SearXNG MCP tool `mcp__searxng__web_url_read` (load its schema via ToolSearch \"select:mcp__searxng__web_url_read\" if needed). Do NOT use WebFetch for this sensitive topic",
    }
  : { searchHow: "WebSearch", fetchHow: "WebFetch" }

// Angle budget: complexity cap, tightened for sensitive, then an explicit numeric override wins.
let angleCap = ANGLE_CAP[scope.complexity] || 5
if (SENSITIVE) angleCap = Math.min(angleCap, SENSITIVE_ANGLE_CAP)
if (ovAngles != null) angleCap = ovAngles
let activeAngles = scope.angles.slice(0, angleCap)

// Follow-up wave: on by default for normal topics, HARD-DISABLED for sensitive (amplification control),
// and overridable via args.secondWave.
const secondWaveAllowed = secondWaveOpt != null ? secondWaveOpt : !SENSITIVE

log("Q: " + QUESTION.slice(0, 80) + (QUESTION.length > 80 ? "…" : ""))
log("Complexity: " + scope.complexity + " → " + activeAngles.length + " angle(s) [retriever=" + researchModel + "]: " + activeAngles.map(a => a.label).join(", "))
if (SENSITIVE) {
  log("⚠ SENSITIVE topic" + (forceMode === "sensitive" ? " (forced)" : "") + " — route via self-hosted SearXNG, reduced fan-out (angles≤" + angleCap + "), follow-up wave OFF. " + (sensitiveConfirmed ? "Confirmed — proceeding." : "GATING for confirmation."))
} else {
  log("Topic assessed normal" + (forceMode === "normal" ? " (forced)" : "") + " — WebSearch/WebFetch, follow-up wave " + (secondWaveAllowed ? "ON" : "OFF") + ".")
}

// ─── GATE: stop before any external query fires, unless confirmed ───
if (SENSITIVE && !sensitiveConfirmed) {
  return {
    status: "awaiting-confirmation",
    question: QUESTION,
    sensitivity: "sensitive",
    complexity: scope.complexity,
    rationale: scope.sensitivityRationale || "",
    redactionNotes: scope.redactionNotes || "",
    plan: {
      searchEngine: "self-hosted SearXNG (mcp__searxng__searxng_web_search)",
      fetchTool: "SearXNG mcp__searxng__web_url_read",
      angles: activeAngles.map(a => ({ label: a.label, query: a.query })),
      followUpWave: false,
    },
    note: "Privacy-sensitive topic detected — NO external query has fired yet. Review the redacted queries above. To run: re-invoke with args {question, sensitiveConfirmed: true}. To override the routing (full fan-out via WebSearch/WebFetch): args {question, mode: 'normal'}.",
  }
}

// ─── Researcher subagent: the worker. Owns its context. Does its own search→read→extract. ───
// When breadth>1, each of an angle's researchers gets a different LENS so extra Haiku buys distinct
// recall, not a repeated search. The first lens is the plain broad pass.
const LENSES = [
  "",
  "Bias THIS pass toward the most RECENT developments — newest openings, latest news, just-announced.",
  "Bias THIS pass toward critical acclaim — awards, Michelin/James Beard, and 'best new' critic lists.",
  "Bias THIS pass toward under-the-radar / overlooked / contrarian picks the mainstream lists miss.",
  "Bias THIS pass toward PRIMARY sources — official sites, reservation platforms, first-hand interviews.",
  "Bias THIS pass toward local/neighborhood coverage and practitioner/enthusiast reviews.",
]
const RESEARCHER_PROMPT = (angle, alreadyCovered, lens) =>
  "## Researcher — angle: " + angle.label + "\n\n" +
  "You are one of several researchers investigating a question in parallel. You are a RETRIEVER: search, read, and pull cited findings — not raw pages. A later synthesis step does the final trust judgment and confidence calibration, so favor RECALL — when unsure whether something is relevant, INCLUDE it (with its quote + source) rather than dropping it. Own THIS angle end to end.\n\n" +
  "## Research question\n" + QUESTION + "\n\n" +
  "## Your angle\n**" + angle.label + "** — " + (angle.rationale || "") + "\nStarting query: `" + angle.query + "`\n\n" +
  (lens ? "## Lens\n" + lens + " (Other researchers cover the broad view — you go deep on this slant.)\n\n" : "") +
  (SENSITIVE ? "NOTE: privacy-sensitive topic — the starting query is intentionally generalized. Keep your searches generalized; do NOT re-add identifying specifics (names, exact addresses, account numbers, internal codenames, target-specific detail).\n\n" : "") +
  (alreadyCovered && alreadyCovered.length
    ? "## Already covered by earlier researchers (don't just re-find these — go deeper or elsewhere)\n" + alreadyCovered.map(s => "- " + s).join("\n") + "\n\n"
    : "") +
  "## Method (start wide, then narrow)\n" +
  "1. Search with " + tools.searchHow + ", starting BROAD, then narrow based on what you see. Short queries first; specific follow-ups after.\n" +
  "2. Read the most promising sources with " + tools.fetchHow + ". Prefer primary/authoritative sources over SEO content farms.\n" +
  "3. Make roughly 3-8 tool calls total — scale to the angle. STOP once you have solid coverage; don't chase nonexistent sources or keep going after the angle is answered.\n\n" +
  "## Return\n" +
  "Extract up to 8 FALSIFIABLE findings that bear on the research question. Each finding:\n" +
  "- a concrete, checkable claim (not a vague generality)\n" +
  "- a ROUGH first-pass confidence (high/medium/low) — synthesis finalizes it, so don't agonize\n" +
  "- the source URL + a direct supporting quote from that source (the quote is what matters — grounding depends on it)\n" +
  "- a rough source-type tag (primary/secondary/blog/forum/unreliable) and importance (central/supporting/tangential)\n" +
  "Also give a one-line coverageNote: what this angle turned up and what it couldn't find.\n" +
  "If you find nothing usable, return findings: [] with a coverageNote explaining why.\n\nStructured output only."

// Run a wave of researchers in parallel; each is blind to its siblings (overlap is fine, synthesis merges).
// perAngle>1 spawns that many researchers per angle, each on a different lens (LENSES), for wider recall.
const runWave = (angles, alreadyCovered, waveTag, perAngle = 1) =>
  parallel(
    angles.flatMap(angle =>
      Array.from({ length: perAngle }, (_, v) => () =>
        agent(RESEARCHER_PROMPT(angle, alreadyCovered, LENSES[v % LENSES.length]), {
          label: waveTag + ":" + angle.label + (perAngle > 1 ? "#" + v : ""),
          phase: "Research",
          schema: BRIEF_SCHEMA,
          model: researchModel,
        }).then(brief => {
          if (!brief) return null
          log(angle.label + (perAngle > 1 ? "#" + v : "") + ": " + brief.findings.length + " findings" + (Number.isFinite(brief.searchesRun) ? " (" + brief.searchesRun + " searches)" : ""))
          // Tag with the DISPATCHED angle label (deterministic), NOT the researcher's self-reported
          // angleLabel, which Haiku phrases differently each call and would fragment sharded synthesis.
          return { ...brief, dispatchedAngle: angle.label }
        }).catch(e => {
          log("researcher failed: " + angle.label + " — " + (e.message || e))
          return null
        })
      )
    )
  ).then(rs => rs.filter(Boolean))

// ─── Phase 1: first research wave ───
phase("Research")
if (breadth > 1) log("Breadth=" + breadth + " → " + (activeAngles.length * breadth) + " Haiku researchers (" + breadth + " lenses/angle)")
const briefs = await runWave(activeAngles, [], "research", breadth)

let allFindings = briefs.flatMap(b => b.findings.map(f => ({ ...f, angle: b.dispatchedAngle || b.angleLabel })))
const coveredSummary = () => {
  const bySrc = new Map()
  for (const f of allFindings) {
    const host = (() => { try { return new URL(f.sourceUrl).hostname.replace(/^www\./, "") } catch { return f.sourceUrl } })()
    bySrc.set(host, (bySrc.get(host) || 0) + 1)
  }
  return [...bySrc.keys()]
}

log("First wave: " + briefs.length + " researchers → " + allFindings.length + " findings from " + coveredSummary().length + " sources")

// ─── Phase 2: gap check: one pass, optional single follow-up wave ───
let gap = null
if (secondWaveAllowed && allFindings.length > 0) {
  phase("Gap check")
  const digest = briefs.map(b =>
    "### " + b.angleLabel + " (" + b.findings.length + " findings)\n" +
    "Coverage: " + (b.coverageNote || "—") + "\n" +
    b.findings.map(f => "- [" + f.confidence + "] " + f.claim).join("\n")
  ).join("\n\n")

  gap = await agent(
    "## Gap check\n\n" +
    "Research question:\n" + QUESTION + "\n\n" +
    "The first research wave covered these angles and findings:\n\n" + digest + "\n\n" +
    "## Task\nJudge whether this coverage is SUFFICIENT to answer the question well.\n" +
    "- If yes: return sufficient=true, empty followUpAngles.\n" +
    "- If no: name the specific gaps (a facet not covered, a claim needing corroboration from another source type, a missing recent development, an unexamined counter-view), and propose up to " + MAX_FOLLOWUP_ANGLES + " follow-up angles with starting queries that would close them.\n" +
    "Be disciplined: only ask for a follow-up wave if it would materially improve the answer. Redundant re-searching is waste.\n" +
    (SENSITIVE ? "PRIVACY: keep any follow-up queries generalized — no identifying specifics.\n" : "") +
    "\nStructured output only.",
    { label: "gap-check", schema: GAP_SCHEMA, model: "sonnet" }
  )

  if (gap && !gap.sufficient && gap.followUpAngles && gap.followUpAngles.length) {
    const followUps = gap.followUpAngles.slice(0, MAX_FOLLOWUP_ANGLES)
    log("Gaps found: " + (gap.gaps || []).length + " → follow-up wave on " + followUps.length + " angle(s): " + followUps.map(a => a.label).join(", "))
    phase("Research")
    const followBriefs = await runWave(followUps, coveredSummary(), "followup")
    const extra = followBriefs.flatMap(b => b.findings.map(f => ({ ...f, angle: b.dispatchedAngle || b.angleLabel })))
    log("Follow-up wave: " + followBriefs.length + " researchers → " + extra.length + " more findings")
    briefs.push(...followBriefs)
    allFindings = allFindings.concat(extra)
  } else {
    log("Coverage sufficient — no follow-up wave.")
  }
}

if (allFindings.length === 0) {
  return {
    question: QUESTION,
    summary: "No findings extracted. " + briefs.length + " researcher(s) ran but surfaced nothing usable — sources may be sparse, paywalled, or the angles missed.",
    findings: [],
    sources: [],
    stats: { complexity: scope.complexity, sensitivity: SENSITIVE ? "sensitive" : "normal", researchers: briefs.length, findings: 0 },
  }
}

// Deterministic dedup of gathered findings: merges near-identical claims across researchers, unions
// their sources, counts corroboration. Used by harvest mode AND as the synthesis-failure fallback.
// No LLM, so it never stalls. The reliable path for very large exhaustive sets.
const dedupeFindings = findings => {
  const confRank = { high: 0, medium: 1, low: 2 }
  const impRank = { central: 0, supporting: 1, tangential: 2 }
  const key = c => (c || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().split(" ").slice(0, 10).join(" ")
  const groups = new Map()
  for (const f of findings) {
    const k = key(f.claim)
    if (!k) continue
    if (!groups.has(k)) groups.set(k, { claim: f.claim, confidence: f.confidence, quote: f.quote, importance: f.importance, angle: f.angle, sources: new Set(), corroborations: 0 })
    const g = groups.get(k)
    g.corroborations++
    if (f.sourceUrl) g.sources.add(f.sourceUrl)
    // Keep the highest-confidence representative claim/quote for the group.
    if ((confRank[f.confidence] ?? 3) < (confRank[g.confidence] ?? 3)) { g.claim = f.claim; g.confidence = f.confidence; g.quote = f.quote }
  }
  return [...groups.values()]
    .map(g => ({ claim: g.claim, confidence: g.confidence, sources: [...g.sources], quote: g.quote, corroborations: g.corroborations, importance: g.importance, angle: g.angle }))
    .sort((a, b) => (impRank[a.importance] ?? 1) - (impRank[b.importance] ?? 1) || b.corroborations - a.corroborations || (confRank[a.confidence] ?? 3) - (confRank[b.confidence] ?? 3))
}
const buildSources = () => [...new Map(allFindings.map(f => [f.sourceUrl, { url: f.sourceUrl, title: f.sourceTitle, quality: f.sourceQuality, angle: f.angle }])).values()]

// ─── Harvest mode: skip the LLM reduce entirely (no stall risk), return deduped findings ───
if (harvest) {
  phase("Synthesize")
  const deduped = dedupeFindings(allFindings)
  log("Harvest mode: " + allFindings.length + " findings → " + deduped.length + " deduped (no assembly)")
  return {
    question: QUESTION,
    mode: "harvest",
    findings: deduped,
    sources: buildSources(),
    stats: {
      complexity: scope.complexity, sensitivity: SENSITIVE ? "sensitive" : "normal",
      breadth, researchers: briefs.length,
      findingsGathered: allFindings.length, findingsDeduped: deduped.length,
      agentCalls: 1 + briefs.length + (gap ? 1 : 0),
    },
  }
}

// ─── Phase 3: synthesize: merge, GROUND to sources (drop ungrounded), cite ───
phase("Synthesize")
const impRank = { central: 0, supporting: 1, tangential: 2 }
const qualRank = { primary: 0, secondary: 1, blog: 2, forum: 3, unreliable: 4 }
const rankedFindings = [...allFindings].sort((a, b) =>
  (impRank[a.importance] ?? 1) - (impRank[b.importance] ?? 1) ||
  (qualRank[a.sourceQuality] ?? 2) - (qualRank[b.sourceQuality] ?? 2)
)

const block = rankedFindings.map((f, i) =>
  "### [" + i + "] " + f.claim + "\n" +
  "Confidence: " + f.confidence + " · Importance: " + (f.importance || "—") + " · Angle: " + f.angle + "\n" +
  "Source: " + f.sourceUrl + " (" + (f.sourceQuality || "unrated") + ")\n" +
  "Quote: \"" + (f.quote || "") + "\"\n"
).join("\n")

// Synthesis mode: a SINGLE Opus pass over all findings compresses to a fixed ~20-25 items no matter how
// many were gathered (the "funnel"). SHARDED = map-reduce: cluster by angle, one Sonnet synthesizer per
// section (each keeps ITS findings, so output width scales with real content), then ONE Opus pass ASSEMBLES
// the sections (dedup + summary), not extracts from raw. Auto-shards past SHARD_MIN gathered findings.
const SHARD = synthesisMode === "sharded" || (synthesisMode === "auto" && allFindings.length > SHARD_MIN)

let report
if (SHARD) {
  // Map: cluster by originating angle, synthesize each section on Sonnet, keeping every distinct finding.
  const byAngle = new Map()
  for (const f of rankedFindings) {
    if (!byAngle.has(f.angle)) byAngle.set(f.angle, [])
    byAngle.get(f.angle).push(f)
  }
  const sectionEntries = [...byAngle.entries()]
  log("Sharded synthesis: " + sectionEntries.length + " Sonnet sections → 1 Opus assembly (" + allFindings.length + " findings)")
  const secBlock = fs => fs.map((f, i) =>
    "### [" + i + "] " + f.claim + "\nConfidence: " + f.confidence + " · Source: " + f.sourceUrl + " (" + (f.sourceQuality || "unrated") + ")\nQuote: \"" + (f.quote || "") + "\"\n"
  ).join("\n")
  const sections = (await parallel(sectionEntries.map(([angle, fs]) => () =>
    agent(
      "## Section synthesis — " + angle + "\n\n" +
      "**Question:** " + QUESTION + "\n\n" +
      "Merge and ground the findings for THIS section only. Keep EVERY distinct grounded finding — do NOT drop for brevity; only merge true duplicates (combine their sources).\n\n" +
      "## Findings (each carries its source + quote)\n" + secBlock(fs) + "\n\n" +
      "## Rules\n" +
      "- Ground: every finding cites ≥1 source URL above; drop anything not supported by a quote here.\n" +
      "- Merge only findings that are the SAME thing; otherwise keep them separate.\n" +
      "- Confidence: high (multiple/primary agree), medium (single good/secondary), low (single blog/forum/thin).\n\nStructured output only.",
      { label: "section:" + angle, phase: "Synthesize", schema: SECTION_SCHEMA, model: "sonnet" }
    ).then(s => (s && s.findings.length) ? { section: angle, findings: s.findings } : null)
  ))).filter(Boolean)

  // Reduce: ONE Opus pass over the section outputs (compact; assembly, not extraction), told to preserve breadth.
  const asmBlock = sections.map(s =>
    "## Section: " + s.section + "\n" + s.findings.map(f =>
      "- " + f.claim + " [" + f.confidence + "] (" + (f.sources || []).join(", ") + ")" + (f.evidence ? " — " + f.evidence : "")
    ).join("\n")
  ).join("\n\n")
  report = await agent(
    "## Final assembly: research report\n\n" +
    "**Question:** " + QUESTION + "\n\n" +
    "The findings below are ALREADY grounded and merged within each section. Assemble them into one report.\n\n" +
    asmBlock + "\n\n" +
    "## Instructions\n" +
    "1. **Preserve breadth.** Include EVERY distinct finding across sections. Merge only findings that are the SAME across sections (combine their sources). Do NOT drop findings for brevity — a long findings list is expected and correct.\n" +
    "2. Carry each finding's confidence and sources; write a one-line evidence note per finding.\n" +
    "3. Write a 3-5 sentence executive summary answering the question.\n" +
    "4. Note caveats (what's uncertain, weak sources, time-sensitivity) and 2-4 open questions.\n\nStructured output only.",
    { label: "assemble", schema: REPORT_SCHEMA }
  )
} else {
  report = await agent(
    "## Synthesis: research report\n\n" +
    "**Question:** " + QUESTION + "\n\n" +
    rankedFindings.length + " cited findings were gathered by the research wave(s). Synthesize them into a report.\n\n" +
    "## Findings (each carries its source + supporting quote)\n" + block + "\n\n" +
    "## Instructions\n" +
    "1. **Ground everything.** Every finding in your report MUST cite at least one source URL from the list above. If a claim isn't supported by any source's quote here, DROP it — do not add outside knowledge as if it were sourced.\n" +
    "2. **Merge duplicates.** Findings that say the same thing become one finding with combined sources.\n" +
    "3. **Group into coherent findings** that directly address the question.\n" +
    "4. **Assign confidence per finding:** high (multiple independent/primary sources agree), medium (secondary sources, or single good source), low (single blog/forum source, or thin support).\n" +
    "5. Write a 3-5 sentence executive summary answering the question.\n" +
    "6. Note caveats: what's uncertain, which sources were weak, what time-sensitivity applies, where coverage was thin.\n" +
    "7. List 2-4 open questions that surfaced but weren't answered.\n\nStructured output only.",
    { label: "synthesize", schema: REPORT_SCHEMA }
  )
}

if (!report) {
  // Synthesis failed (e.g. the assembly stalled on a very large set). Fall back to a deduped HARVEST
  // rather than discarding the run or dumping unmerged duplicates. This is the harvest path, reused.
  const deduped = dedupeFindings(allFindings)
  log("Synthesis failed — falling back to deduped harvest: " + allFindings.length + " → " + deduped.length)
  return {
    question: QUESTION,
    mode: "harvest-fallback",
    summary: "Final assembly failed — returning " + deduped.length + " deduped findings (from " + allFindings.length + " gathered).",
    findings: deduped,
    sources: buildSources(),
    stats: { complexity: scope.complexity, sensitivity: SENSITIVE ? "sensitive" : "normal", breadth, researchers: briefs.length, findingsGathered: allFindings.length, findingsDeduped: deduped.length, afterSynthesis: 0 },
  }
}

const sources = [...new Map(allFindings.map(f => [f.sourceUrl, { url: f.sourceUrl, title: f.sourceTitle, quality: f.sourceQuality, angle: f.angle }])).values()]

return {
  question: QUESTION,
  ...report,
  sources,
  stats: {
    complexity: scope.complexity,
    sensitivity: SENSITIVE ? "sensitive" : "normal",
    angles: activeAngles.length,
    breadth,
    synthesis: SHARD ? "sharded" : "single",
    researchers: briefs.length,
    followUpWave: !!(gap && !gap.sufficient && gap.followUpAngles && gap.followUpAngles.length),
    findingsGathered: allFindings.length,
    sourcesUsed: sources.length,
    findingsReported: report.findings.length,
    // agent calls: 1 scope + researchers + (gap? 1 : 0) + 1 synth
    agentCalls: 1 + briefs.length + (gap ? 1 : 0) + 1,
  },
}

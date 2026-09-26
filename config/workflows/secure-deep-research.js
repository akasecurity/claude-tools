export const meta = {
  name: 'secure-deep-research',
  description: 'Deep, fact-checked web research with per-claim adversarial verification, ending in a cited report. Use when the user wants to research, investigate, fact-check, or dig deep into a topic and correctness matters: "deep dive", "verify", "due diligence", "is it true that", "get me sources on". Privacy-aware: sensitive topics are gated, redacted, and routed through self-hosted SearXNG. Pick this when claims need verifying, not just grounding.',
  whenToUse: 'For thorough, verification-grade research where being wrong is costly. If the question is underspecified (e.g. "what car to buy" with no budget/use-case/region), ask 2-3 clarifying questions first, then pass the refined question as args.',
  phases: [{"title":"Scope","detail":"Decompose question + classify privacy sensitivity (no web access — safe to run before gating)"},{"title":"Search","detail":"parallel search agents, one per angle","model":"haiku"},{"title":"Fetch","detail":"URL-dedup, fetch sources, extract falsifiable claims","model":"haiku"},{"title":"Verify","detail":"3-vote adversarial verification per claim (need 2/3 refutes to kill)","model":"sonnet"},{"title":"Synthesize","detail":"Merge semantic dupes, rank by confidence, cite sources"}],
}

// secure-deep-research: Scope+triage → [gate?] → pipeline(Search → URL-dedup → Fetch+Extract) → 3-vote Verify → Synthesize
// Privacy-aware fork of the stock built-in `deep-research` workflow.
// Ported from bughunter architecture. WebSearch/WebFetch by default.
//
// Model tiering: Scope + Synthesize inherit the session model (Sonnet/Opus/…): the reasoning-heavy ends.
// The retrieval fan-out (Search + Fetch) is pinned to Haiku to cut cost. The 3-vote adversarial Verify
// stays on Sonnet, a last-word gate where Haiku over-refutes and kills true claims.
//
// Privacy intelligence: the fan-out amplifies a single topic into ~30 external queries (5 angles +
// 15 fetches + 25 verifier re-searches), so a sensitive topic gets sprayed across third-party engines
// many times over. To contain that, the Scope agent classifies sensitivity (conservatively, when in
// doubt, sensitive), and for sensitive topics the workflow:
//   1. REDACTS: Scope generalizes identifying specifics out of the search queries (full question stays internal).
//   2. GATES: returns the plan for confirmation BEFORE any external query fires (Scope has no web access).
//   3. REDUCES: fewer angles, fewer fetches, fewer verified claims, and verifier web-search disabled.
//   4. ROUTES: search + fetch go through self-hosted SearXNG (de-identified vs. upstream engines).
// NOTE: this de-identifies, it does not cloak. Upstream engines still see query text, and the model
// already has the full question. The redaction + reduced amplification do more for privacy than the
// engine swap alone.
//
// Invocation:
//   Workflow({name:'secure-deep-research', args:'<question>'})                              // string form
//   Workflow({name:'secure-deep-research', args:{question:'...', sensitiveConfirmed:true}}) // proceed past the gate
//   Workflow({name:'secure-deep-research', args:{question:'...', mode:'normal'|'sensitive'}}) // force the routing

const VOTES_PER_CLAIM = 3
const REFUTATIONS_REQUIRED = 2
const MAX_FETCH = 15
const MAX_VERIFY_CLAIMS = 25
// Reduced fan-out applied to privacy-sensitive topics:
const SENSITIVE_ANGLES = 3
const SENSITIVE_MAX_FETCH = 6
const SENSITIVE_MAX_VERIFY_CLAIMS = 12

// ─── Schemas ───
const SCOPE_SCHEMA = {
  type: "object", required: ["question", "angles", "summary", "sensitivity"],
  properties: {
    question: { type: "string" },
    summary: { type: "string" },
    sensitivity: { enum: ["normal", "sensitive"] },
    sensitivityRationale: { type: "string" },
    redactionNotes: { type: "string" },
    angles: { type: "array", minItems: 3, maxItems: 6, items: {
      type: "object", required: ["label", "query"],
      properties: {
        label: { type: "string" },
        query: { type: "string" },
        rationale: { type: "string" },
      },
    }},
  },
}
const SEARCH_SCHEMA = {
  type: "object", required: ["results"],
  properties: {
    results: { type: "array", maxItems: 6, items: {
      type: "object", required: ["url", "title", "relevance"],
      properties: {
        url: { type: "string" },
        title: { type: "string" },
        snippet: { type: "string" },
        relevance: { enum: ["high", "medium", "low"] },
      },
    }},
  },
}
const EXTRACT_SCHEMA = {
  type: "object", required: ["claims", "sourceQuality"],
  properties: {
    sourceQuality: { enum: ["primary", "secondary", "blog", "forum", "unreliable"] },
    publishDate: { type: "string" },
    claims: { type: "array", maxItems: 5, items: {
      type: "object", required: ["claim", "quote", "importance"],
      properties: {
        claim: { type: "string" },
        quote: { type: "string" },
        importance: { enum: ["central", "supporting", "tangential"] },
      },
    }},
  },
}
const VERDICT_SCHEMA = {
  type: "object", required: ["refuted", "evidence", "confidence"],
  properties: {
    refuted: { type: "boolean" },
    evidence: { type: "string" },
    confidence: { enum: ["high", "medium", "low"] },
    counterSource: { type: "string" },
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
        vote: { type: "string" },
      },
    }},
    caveats: { type: "string" },
    openQuestions: { type: "array", items: { type: "string" } },
  },
}

// ─── Parse args: string question, or {question, sensitiveConfirmed, mode} ───
let QUESTION = "", sensitiveConfirmed = false, forceMode = null
if (typeof args === "string") {
  QUESTION = args.trim()
} else if (args && typeof args === "object") {
  QUESTION = (args.question || "").trim()
  sensitiveConfirmed = !!args.sensitiveConfirmed
  forceMode = args.mode === "normal" || args.mode === "sensitive" ? args.mode : null
}
if (!QUESTION) {
  return { error: "No research question provided. Pass it as args: Workflow({name: 'secure-deep-research', args: '<question>'}) or args: {question, sensitiveConfirmed, mode}." }
}

// ─── Phase 0: Scope: decompose question + classify privacy sensitivity ───
// Pure reasoning, NO web access: safe to run before the gate. Nothing leaves the host yet.
phase("Scope")
const scope = await agent(
  "Decompose this research question into complementary search angles, and classify its privacy sensitivity.\n\n" +
  "## Question\n" + QUESTION + "\n\n" +
  "## Task A — sensitivity triage (be CONSERVATIVE: when in doubt, mark sensitive)\n" +
  "Mark **sensitive** if researching this would spray identifying or private terms across third-party search engines in a way the user likely wouldn't want, e.g.: a named/identifiable private individual; health, medical, legal, or personal-financial specifics tied to a person; sexuality/religion/political affiliation of identifiable people; security vulnerabilities tied to a specific target/host; credentials, account numbers, internal codenames, or business-confidential material. Mark **normal** for general/public/technical topics with no private specifics.\n" +
  "Give a one-line sensitivityRationale.\n\n" +
  "## Task B — angles\n" +
  "Generate distinct web search queries that together cover the question from different angles (5 for normal topics, 3 for sensitive). Pick angles that suit the domain. Examples:\n" +
  "- broad/primary · academic/technical · recent news · contrarian/skeptical · practitioner/implementation\n" +
  "- For tech: state-of-art · benchmarks · limitations · industry adoption · cost/tradeoffs\n" +
  "Make queries specific enough to surface high-signal results. Avoid redundancy.\n\n" +
  "## Task C — redaction (ONLY if sensitive)\n" +
  "If sensitive, write each search `query` to GENERALIZE AWAY the most identifying/sensitive specifics while preserving research intent — e.g., abstract a personal name to a role/category, drop exact addresses/account numbers/internal codenames, broaden a target-specific vuln to the general class. The full unredacted question stays internal (for synthesis); only the outgoing queries are redacted. Record what you generalized in redactionNotes. If normal, leave redactionNotes empty and use queries as-is.\n\n" +
  "Return: the question (verbatim or lightly normalized), a 1-2 sentence decomposition strategy (summary), sensitivity + sensitivityRationale, redactionNotes, and the angles.\n\nStructured output only.",
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
const limits = SENSITIVE
  ? { maxFetch: SENSITIVE_MAX_FETCH, maxVerify: SENSITIVE_MAX_VERIFY_CLAIMS, verifySearch: false }
  : { maxFetch: MAX_FETCH, maxVerify: MAX_VERIFY_CLAIMS, verifySearch: true }
const activeAngles = SENSITIVE ? scope.angles.slice(0, SENSITIVE_ANGLES) : scope.angles

log("Q: " + QUESTION.slice(0, 80) + (QUESTION.length > 80 ? "…" : ""))
log("Decomposed into " + activeAngles.length + " angles: " + activeAngles.map(a => a.label).join(", "))
if (SENSITIVE) {
  log("⚠ SENSITIVE topic" + (forceMode === "sensitive" ? " (forced)" : "") + " — route via self-hosted SearXNG, reduced fan-out (fetch≤" + limits.maxFetch + ", verify-claims≤" + limits.maxVerify + ", verifier web-search OFF). " + (sensitiveConfirmed ? "Confirmed — proceeding." : "GATING for confirmation."))
} else {
  log("Topic assessed normal" + (forceMode === "normal" ? " (forced)" : "") + " — WebSearch/WebFetch, full fan-out.")
}

// ─── GATE: stop before any external query fires, unless confirmed ───
if (SENSITIVE && !sensitiveConfirmed) {
  return {
    status: "awaiting-confirmation",
    question: QUESTION,
    sensitivity: "sensitive",
    rationale: scope.sensitivityRationale || "",
    redactionNotes: scope.redactionNotes || "",
    plan: {
      searchEngine: "self-hosted SearXNG (mcp__searxng__searxng_web_search)",
      fetchTool: "SearXNG mcp__searxng__web_url_read",
      angles: activeAngles.map(a => ({ label: a.label, query: a.query })),
      maxFetch: limits.maxFetch,
      maxVerifyClaims: limits.maxVerify,
      verifierWebSearch: false,
    },
    note: "Privacy-sensitive topic detected — NO external query has fired yet. Review the redacted queries above. To run: re-invoke with args {question, sensitiveConfirmed: true}. To override the routing (full fan-out via WebSearch/WebFetch): args {question, mode: 'normal'}.",
  }
}

// ─── Dedup state: accumulates across searchers as they complete ───
const normURL = u => {
  try {
    const p = new URL(u)
    return (p.hostname.replace(/^www\./, "") + p.pathname.replace(/\/$/, "")).toLowerCase()
  } catch { return u.toLowerCase() }
}
const seen = new Map()
const dupes = []
const budgetDropped = []
const relRank = { high: 0, medium: 1, low: 2 }
let fetchSlots = limits.maxFetch

// ─── Prompts (tool choice + verifier-search depend on sensitivity) ───
const SEARCH_PROMPT = (angle) =>
  "## Web Searcher: " + angle.label + "\n\n" +
  "Research question: \"" + QUESTION + "\"\n\n" +
  "Your angle: **" + angle.label + "** — " + (angle.rationale || "") + "\n" +
  "Search query: `" + angle.query + "`\n\n" +
  (SENSITIVE ? "NOTE: privacy-sensitive topic — the query above is intentionally generalized. Search it AS GIVEN; do not re-add identifying specifics.\n\n" : "") +
  "## Task\nUse " + tools.searchHow + " with the query above (or a refined version). Return the top 4-6 most relevant results.\n" +
  "Rank by relevance to the ORIGINAL question, not just the search query. Skip obvious SEO spam/content farms.\n" +
  "Include a short snippet capturing why each result is relevant.\n\nStructured output only."

const FETCH_PROMPT = (source, angle) =>
  "## Source Extractor\n\n" +
  "Research question: \"" + QUESTION + "\"\n\n" +
  "Fetch and extract key claims from this source:\n" +
  "**URL:** " + source.url + "\n**Title:** " + source.title + "\n**Found via:** " + angle + " search\n\n" +
  "## Task\n1. Use " + tools.fetchHow + " to retrieve the page content.\n" +
  "2. Assess source quality: primary research/institution? secondary reporting? blog/opinion? forum? unreliable?\n" +
  "3. Extract 2-5 FALSIFIABLE claims that bear on the research question. Each claim must:\n" +
  "   - be a concrete, checkable statement (not vague generalities)\n" +
  "   - include a direct quote from the source as support\n" +
  "   - be rated central/supporting/tangential to the research question\n" +
  "4. Note publish date if available.\n\n" +
  "If the fetch fails or the page is irrelevant/paywalled, return claims: [] and sourceQuality: \"unreliable\".\n\nStructured output only."

const VERIFY_PROMPT = (claim, v) =>
  "## Adversarial Claim Verifier (voter " + (v + 1) + "/" + VOTES_PER_CLAIM + ")\n\n" +
  "Be SKEPTICAL. Try to REFUTE this claim. ≥" + REFUTATIONS_REQUIRED + "/" + VOTES_PER_CLAIM + " refutations kill it.\n\n" +
  "## Research question\n" + QUESTION + "\n\n" +
  "## Claim under review\n\"" + claim.claim + "\"\n\n" +
  "**Source:** " + claim.sourceUrl + " (" + claim.sourceQuality + ")\n" +
  "**Supporting quote:** \"" + claim.quote + "\"\n\n" +
  "## Checklist\n" +
  "1. Is the claim actually supported by the quote, or is it an overreach/misread?\n" +
  (limits.verifySearch
    ? "2. Use " + tools.searchHow + " for contradicting evidence — does any credible source dispute or heavily qualify this?\n"
    : "2. PRIVACY-SENSITIVE TOPIC — do NOT perform any web search (avoid re-querying external engines with sensitive terms). Judge using only the supplied quote, the source quality, and your own knowledge.\n") +
  "3. Is the source quality sufficient for the claim's strength? (extraordinary claims need primary sources)\n" +
  "4. Is the claim outdated? (check dates — old claims about fast-moving fields are suspect)\n" +
  "5. Is this a marketing claim / press release / cherry-picked benchmark / forum speculation?\n\n" +
  "**refuted=true** if: unsupported by quote / contradicted / low-quality source for strong claim / outdated / marketing fluff.\n" +
  "**refuted=false** ONLY if: claim is well-supported, current, and source quality matches claim strength.\n" +
  "Default to refuted=true if uncertain.\n\nStructured output only. Evidence MUST be specific."

// ─── Pipeline: search → dedup → fetch+extract (no barrier) ───
const searchResults = await pipeline(
  activeAngles,

  angle => agent(SEARCH_PROMPT(angle), {
    label: "search:" + angle.label, phase: "Search", schema: SEARCH_SCHEMA, model: "haiku"
  }).then(r => {
    if (!r) return null
    log(angle.label + ": " + r.results.length + " results")
    return { angle: angle.label, results: r.results }
  }),

  searchResult => {
    const sorted = [...searchResult.results].sort((a, b) => relRank[a.relevance] - relRank[b.relevance])
    const novel = sorted.filter(r => {
      const key = normURL(r.url)
      if (seen.has(key)) {
        dupes.push({ ...r, angle: searchResult.angle, dupOf: seen.get(key) })
        return false
      }
      if (fetchSlots <= 0 && relRank[r.relevance] >= 1) {
        budgetDropped.push({ ...r, angle: searchResult.angle })
        return false
      }
      seen.set(key, { angle: searchResult.angle, title: r.title })
      fetchSlots--
      return true
    })
    if (novel.length < searchResult.results.length) {
      log(searchResult.angle + ": " + novel.length + " novel (" + (searchResult.results.length - novel.length) + " filtered)")
    }
    return parallel(
      novel.map(source => () => {
        let host = "unknown"
        try { host = new URL(source.url).hostname.replace(/^www\./, "") } catch {}
        return agent(FETCH_PROMPT(source, searchResult.angle), {
          label: "fetch:" + host,
          phase: "Fetch",
          schema: EXTRACT_SCHEMA,
          model: "haiku",
        }).then(ext => {
          // User-skip → null; drop it (filtered by searchResults.flat().filter(Boolean))
          // rather than throwing into .catch() and mislabeling it "unreliable".
          if (!ext) return null
          return {
            url: source.url, title: source.title, angle: searchResult.angle,
            sourceQuality: ext.sourceQuality, publishDate: ext.publishDate,
            claims: ext.claims.map(c => ({ ...c, sourceUrl: source.url, sourceQuality: ext.sourceQuality })),
          }
        }).catch(e => {
          log("fetch failed: " + source.url + " — " + (e.message || e))
          return { url: source.url, title: source.title, angle: searchResult.angle, sourceQuality: "unreliable", claims: [] }
        })
      })
    )
  }
)

const allSources = searchResults.flat().filter(Boolean)
const allClaims = allSources.flatMap(s => s.claims)
const impRank = { central: 0, supporting: 1, tangential: 2 }
const qualRank = { primary: 0, secondary: 1, blog: 2, forum: 3, unreliable: 4 }

const rankedClaims = [...allClaims]
  .sort((a, b) => (impRank[a.importance] - impRank[b.importance]) || (qualRank[a.sourceQuality] - qualRank[b.sourceQuality]))
  .slice(0, limits.maxVerify)

log("Fetched " + allSources.length + " sources → " + allClaims.length + " claims → verifying top " + rankedClaims.length)

if (rankedClaims.length === 0) {
  return {
    question: QUESTION,
    summary: "No claims extracted. " + allSources.length + " sources fetched, all empty/failed. " + dupes.length + " URL dupes, " + budgetDropped.length + " budget-dropped.",
    findings: [], refuted: [], sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality })),
    stats: { angles: activeAngles.length, sensitivity: SENSITIVE ? "sensitive" : "normal", sources: allSources.length, claims: 0, dupes: dupes.length },
  }
}

// ─── Verify: 3-vote adversarial ───
// Barrier here is intentional: claim pool must be fully assembled before ranking/verification.
phase("Verify")
const voted = (await parallel(
  rankedClaims.map(claim => () =>
    parallel(
      Array.from({ length: VOTES_PER_CLAIM }, (_, v) => () =>
        agent(VERIFY_PROMPT(claim, v), {
          label: "v" + v + ":" + claim.claim.slice(0, 40),
          phase: "Verify",
          schema: VERDICT_SCHEMA,
          model: "sonnet",
        })
      )
    ).then(verdicts => {
      // A vote can be null (user-skip or agent error): treat as abstain.
      const valid = verdicts.filter(Boolean)
      const refuted = valid.filter(v => v.refuted).length
      // Survive only if the claim was actually adjudicated: a quorum of
      // valid votes AND fewer than REFUTATIONS_REQUIRED refuting. Too many
      // abstentions = unverified, which must NOT pass into the report
      // (otherwise all-abstain → refuted=0 → false survive).
      const abstained = VOTES_PER_CLAIM - valid.length
      const survives = valid.length >= REFUTATIONS_REQUIRED && refuted < REFUTATIONS_REQUIRED
      log("\"" + claim.claim.slice(0, 50) + "…\": " + (valid.length - refuted) + "-" + refuted + (abstained > 0 ? " (" + abstained + " abstain)" : "") + " " + (survives ? "✓" : "✗"))
      return { ...claim, verdicts: valid, refutedVotes: refuted, survives }
    })
  )
)).filter(Boolean)

const confirmed = voted.filter(c => c.survives)
const killed = voted.filter(c => !c.survives)
log("Verify done: " + voted.length + " claims → " + confirmed.length + " confirmed, " + killed.length + " killed")

if (confirmed.length === 0) {
  return {
    question: QUESTION,
    summary: "All " + voted.length + " claims refuted by adversarial verification. Research inconclusive — sources may be low-quality or claims overstated.",
    findings: [],
    refuted: killed.map(c => ({ claim: c.claim, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes, source: c.sourceUrl })),
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: activeAngles.length, sensitivity: SENSITIVE ? "sensitive" : "normal", sources: allSources.length, claims: allClaims.length, verified: voted.length, confirmed: 0, killed: killed.length },
  }
}

// ─── Synthesize ───
phase("Synthesize")
const confRank = { high: 0, medium: 1, low: 2 }
const block = confirmed.map((c, i) => {
  const best = c.verdicts.filter(v => !v.refuted).sort((a, b) => confRank[a.confidence] - confRank[b.confidence])[0]
  return "### [" + i + "] " + c.claim + "\n" +
    "Vote: " + (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes + " · Source: " + c.sourceUrl + " (" + c.sourceQuality + ")\n" +
    "Quote: \"" + c.quote + "\"\nVerifier evidence (" + best.confidence + "): " + best.evidence + "\n"
}).join("\n")

const killedBlock = killed.length > 0
  ? "\n## Refuted claims (for transparency)\n" +
    killed.map(c => "- \"" + c.claim + "\" (" + c.sourceUrl + ", vote " + (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes + ")").join("\n")
  : ""

const report = await agent(
  "## Synthesis: research report\n\n" +
  "**Question:** " + QUESTION + "\n\n" +
  confirmed.length + " claims survived " + VOTES_PER_CLAIM + "-vote adversarial verification. Merge semantic duplicates and synthesize.\n\n" +
  "## Confirmed claims\n" + block + "\n" + killedBlock + "\n\n" +
  "## Instructions\n" +
  "1. Identify claims that say the same thing — merge them, combine their sources.\n" +
  "2. Group related claims into coherent findings. Each finding should directly address the research question.\n" +
  "3. Assign confidence per finding: high (multiple primary sources, unanimous votes), medium (secondary sources or split votes), low (single source or blog-quality).\n" +
  "4. Write a 3-5 sentence executive summary answering the research question.\n" +
  "5. Note caveats: what's uncertain, what sources were weak, what time-sensitivity applies.\n" +
  "6. List 2-4 open questions that emerged but weren't answered.\n\nStructured output only.",
  { label: "synthesize", schema: REPORT_SCHEMA }
)

if (!report) {
  // Synthesis skipped/errored: salvage the verified claims raw rather
  // than throwing on report.findings and discarding the whole run.
  return {
    question: QUESTION,
    summary: "Synthesis step was skipped or failed — returning " + confirmed.length + " verified claims unmerged.",
    findings: [],
    confirmed: confirmed.map(c => ({ claim: c.claim, source: c.sourceUrl, quote: c.quote, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes })),
    refuted: killed.map(c => ({ claim: c.claim, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes, source: c.sourceUrl })),
    sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, claimCount: s.claims.length })),
    stats: { angles: activeAngles.length, sensitivity: SENSITIVE ? "sensitive" : "normal", sources: allSources.length, claims: allClaims.length, verified: voted.length, confirmed: confirmed.length, killed: killed.length, afterSynthesis: 0 },
  }
}

return {
  question: QUESTION,
  ...report,
  refuted: killed.map(c => ({ claim: c.claim, vote: (c.verdicts.length - c.refutedVotes) + "-" + c.refutedVotes, source: c.sourceUrl })),
  sources: allSources.map(s => ({ url: s.url, quality: s.sourceQuality, angle: s.angle, claimCount: s.claims.length })),
  stats: {
    angles: activeAngles.length,
    sensitivity: SENSITIVE ? "sensitive" : "normal",
    sourcesFetched: allSources.length,
    claimsExtracted: allClaims.length,
    claimsVerified: voted.length,
    confirmed: confirmed.length,
    killed: killed.length,
    afterSynthesis: report.findings.length,
    urlDupes: dupes.length,
    budgetDropped: budgetDropped.length,
    agentCalls: 1 + activeAngles.length + allSources.length + (voted.length * VOTES_PER_CLAIM) + 1,
  },
}

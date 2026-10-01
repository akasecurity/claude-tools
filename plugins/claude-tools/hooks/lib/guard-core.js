// @bun
/*
 * guard-core — vendored from akasecurity/guard-core-dev, MIT, Copyright (c) 2026 William Lin
 *
 * MIT License
 *
 * Copyright (c) 2026 William Lin
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
// package.json
var version = "0.4.0";
// src/shell/tokenize.ts
var TOKENIZE_MAX_DEPTH = 40;
function extractParen(s, from) {
  let depth = 1, i = from, inner = "";
  while (i < s.length && depth > 0) {
    const c = s[i];
    if (c === "\\" && i + 1 < s.length) {
      inner += c + s[i + 1];
      i += 2;
      continue;
    }
    if (c === "'") {
      inner += c;
      i++;
      while (i < s.length && s[i] !== "'") {
        inner += s[i];
        i++;
      }
      if (i < s.length) {
        inner += s[i];
        i++;
      }
      continue;
    }
    if (c === '"') {
      inner += c;
      i++;
      while (i < s.length && s[i] !== '"') {
        if (s[i] === "\\" && i + 1 < s.length) {
          inner += s[i] + s[i + 1];
          i += 2;
          continue;
        }
        inner += s[i];
        i++;
      }
      if (i < s.length) {
        inner += s[i];
        i++;
      }
      continue;
    }
    if (c === "(")
      depth++;
    else if (c === ")") {
      depth--;
      if (depth === 0) {
        i++;
        break;
      }
    }
    inner += c;
    i++;
  }
  return { inner, end: i };
}
function extractBacktick(s, from) {
  let i = from, inner = "";
  while (i < s.length && s[i] !== "`") {
    if (s[i] === "\\" && i + 1 < s.length) {
      inner += s[i] + s[i + 1];
      i += 2;
      continue;
    }
    inner += s[i];
    i++;
  }
  return { inner, end: i + 1 };
}
function tokenize(cmd, depth = 0) {
  if (depth > TOKENIZE_MAX_DEPTH)
    throw new Error("command-guard: substitution nesting too deep");
  const toks = [];
  let word = "", has = false;
  const flush = () => {
    if (has)
      toks.push({ v: word, op: false });
    word = "";
    has = false;
  };
  const spliceInner = (inner) => {
    flush();
    toks.push({ v: ";", op: true });
    for (const t of tokenize(inner, depth + 1))
      toks.push(t);
    toks.push({ v: ";", op: true });
  };
  let i = 0;
  const n = cmd.length;
  while (i < n) {
    const c = cmd[i];
    if (c === " " || c === "\t") {
      flush();
      i++;
      continue;
    }
    if (c === `
`) {
      flush();
      const last = toks[toks.length - 1];
      if (last && !last.op)
        toks.push({ v: `
`, op: true });
      i++;
      continue;
    }
    if (c === "#" && !has) {
      while (i < n && cmd[i] !== `
`)
        i++;
      continue;
    }
    if (c === "\\" && i + 1 < n) {
      word += cmd[i + 1];
      has = true;
      i += 2;
      continue;
    }
    if (c === "'") {
      i++;
      while (i < n && cmd[i] !== "'") {
        word += cmd[i];
        has = true;
        i++;
      }
      i++;
      continue;
    }
    if (c === '"') {
      i++;
      while (i < n && cmd[i] !== '"') {
        if (cmd[i] === "\\" && i + 1 < n) {
          word += cmd[i + 1];
          has = true;
          i += 2;
          continue;
        }
        if (cmd[i] === "$" && cmd[i + 1] === "(") {
          const b = extractParen(cmd, i + 2);
          spliceInner(b.inner);
          i = b.end;
          continue;
        }
        if (cmd[i] === "`") {
          const b = extractBacktick(cmd, i + 1);
          spliceInner(b.inner);
          i = b.end;
          continue;
        }
        word += cmd[i];
        has = true;
        i++;
      }
      i++;
      continue;
    }
    if (c === "$" && cmd[i + 1] === "(") {
      const b = extractParen(cmd, i + 2);
      spliceInner(b.inner);
      i = b.end;
      continue;
    }
    if (c === "`") {
      const b = extractBacktick(cmd, i + 1);
      spliceInner(b.inner);
      i = b.end;
      continue;
    }
    if ((c === "<" || c === ">") && cmd[i + 1] === "(") {
      flush();
      toks.push({ v: c, op: true });
      const b = extractParen(cmd, i + 2);
      spliceInner(b.inner);
      i = b.end;
      continue;
    }
    if (c === "(" || c === ")") {
      flush();
      toks.push({ v: c, op: true });
      i++;
      continue;
    }
    const m = /^(\d*>>|\d*>&|\d*>\||\d*>|&>>|&>|<<<|<<|<|\|\||\|&|\||&&|&|;)/.exec(cmd.slice(i));
    if (m) {
      flush();
      toks.push({ v: m[1], op: true });
      i += m[1].length;
      continue;
    }
    word += c;
    has = true;
    i++;
  }
  flush();
  return toks;
}

// src/shell/bootstrap.ts
var RAW_OK = /^[A-Za-z0-9 \t._~/:=|'"-]+$/;
var SHORT_OK = new Set(["f", "s", "S"]);
var LONG_OK = new Set(["--fail", "--silent", "--show-error", "--tlsv1.2"]);
var HOST_RE = /^[a-z0-9-]+(?:\.[a-z0-9-]+)+$/i;
var SEGMENT = "[A-Za-z0-9._~-]+";
var PREFIX_RE = new RegExp(`^/(?:${SEGMENT}/)*$`);
var URL_RE = new RegExp(`^https://([A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+)((?:/${SEGMENT})+)$`);
var dotSegment = (p) => p.split("/").some((seg) => seg === "." || seg === "..");
function validRule(r) {
  if (!r || typeof r !== "object")
    return false;
  const { host, pathPrefix } = r;
  return typeof host === "string" && HOST_RE.test(host) && typeof pathPrefix === "string" && PREFIX_RE.test(pathPrefix) && !dotSegment(pathPrefix);
}
function urlAllowed(raw, rules) {
  const m = URL_RE.exec(raw);
  if (!m)
    return false;
  const host = m[1].toLowerCase();
  const path = m[2];
  if (dotSegment(path))
    return false;
  let u;
  try {
    u = new URL(raw);
  } catch {
    return false;
  }
  if (u.protocol !== "https:" || u.username || u.password || u.port || u.search || u.hash)
    return false;
  if (u.hostname !== host || u.pathname !== path)
    return false;
  return rules.some((r) => host === r.host.toLowerCase() && path.startsWith(r.pathPrefix));
}
function bootstrapExempt(command, toks, rules) {
  if (!Array.isArray(rules))
    return false;
  const valid = rules.filter(validRule);
  if (valid.length === 0)
    return false;
  if (!RAW_OK.test(command))
    return false;
  const ops = toks.filter((t) => t.op);
  if (ops.length !== 1 || ops[0].v !== "|")
    return false;
  const pipeAt = toks.indexOf(ops[0]);
  const left = toks.slice(0, pipeAt).map((t) => t.v);
  const right = toks.slice(pipeAt + 1).map((t) => t.v);
  if (right.length !== 1 || right[0] !== "bash" && right[0] !== "sh")
    return false;
  if (left[0] !== "curl")
    return false;
  let url = null;
  for (let i = 1;i < left.length; i++) {
    const a = left[i];
    if (a === "--proto") {
      if (left[i + 1] !== "=https")
        return false;
      i++;
      continue;
    }
    if (LONG_OK.has(a))
      continue;
    if (/^-[A-Za-z]+$/.test(a)) {
      if ([...a.slice(1)].every((c) => SHORT_OK.has(c)))
        continue;
      return false;
    }
    if (a.startsWith("-"))
      return false;
    if (url !== null)
      return false;
    url = a;
  }
  return url !== null && urlAllowed(url, valid);
}

// src/shell/detectors.ts
var PIPE_TO_SHELL_RAW = /\|&?\s*(?:(?:\S*\/)?env\s+(?:\S+\s+)*)?(?:\S*\/)?(?:sh|bash|zsh)\b/i;
var STARTUP_WRITE_RAW = /(?:>|\btee\b|\bsed\b|\bcp\b|\bmv\b|\binstall\b|\bln\b|\bdd\b)[^\n]*\.(?:zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\b/;
var SEARCH_EXEC_RAW = /(?:^|[\s'"])--(?:pre|hostname-bin)(?![\w-])|RIPGREP_CONFIG_PATH=/;
var STARTUP_BASENAME = /^\.(zshrc|zshenv|zprofile|bashrc|bash_profile|profile)$/;
var SHELL_INTERPRETERS = new Set(["sh", "bash", "zsh"]);
function isStartupFile(w) {
  const base = w.split("/").pop() ?? w;
  return STARTUP_BASENAME.test(base);
}
function cmdBasename(w) {
  return (w.split("/").pop() ?? w).toLowerCase();
}
function isInterpreterWord(w) {
  return SHELL_INTERPRETERS.has(cmdBasename(w));
}
var SUBSHELL_OPENERS = new Set(["(", "{"]);
var SEARCH_WRAPPERS = new Set(["env", "command", "nice", "ionice", "nohup", "setsid", "stdbuf", "time"]);
var ENV_SETTING_VERBS = new Set(["export", "declare", "typeset", "readonly"]);
var RG_CONFIG_ENV = /^RIPGREP_CONFIG_PATH=/;
function shellInterpreterReadsStdin(toks, j) {
  while (j < toks.length && !toks[j].op) {
    const a = toks[j].v;
    if (a === "--") {
      j++;
      return !(j < toks.length && !toks[j].op);
    }
    if (!a.startsWith("-"))
      return false;
    if (/^-[a-zA-Z]*s/.test(a))
      return true;
    if (/^-[a-zA-Z]*c/.test(a))
      return true;
    if (/^-[a-zA-Z]*[oO]$/.test(a) || a === "--init-file" || a === "--rcfile") {
      if (j + 1 < toks.length && !toks[j + 1].op) {
        j += 2;
        continue;
      }
      return true;
    }
    j++;
  }
  return true;
}
function pipeFeedsShellInterpreter(toks, j) {
  while (j < toks.length && SUBSHELL_OPENERS.has(toks[j].v))
    j++;
  while (j < toks.length && !toks[j].op && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[j].v))
    j++;
  while (j < toks.length && !toks[j].op) {
    if (isInterpreterWord(toks[j].v))
      return shellInterpreterReadsStdin(toks, j + 1);
    if (cmdBasename(toks[j].v) !== "env")
      return false;
    j++;
    while (j < toks.length && !toks[j].op) {
      const a = toks[j].v;
      if (a === "-") {
        j++;
        continue;
      }
      if (a.startsWith("-")) {
        if (/^-[uCPa]$/.test(a))
          j++;
        j++;
        continue;
      }
      if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(a)) {
        j++;
        continue;
      }
      break;
    }
  }
  return false;
}
var CMD_INTRODUCERS = new Set(["do", "then", "else", "elif", "if", "while", "until", "{", "!", "time"]);
function caseAlternationPipes(toks) {
  const marks = new Set;
  const stack = [];
  let atCmdPos = true;
  let prevSemi = false;
  for (let i = 0;i < toks.length; i++) {
    const t = toks[i];
    const top = stack.length ? stack[stack.length - 1] : null;
    if (t.op) {
      if (t.v === "(") {
        atCmdPos = true;
        prevSemi = false;
      } else if (t.v === ")") {
        if (top && top.state === "pattern")
          top.state = "body";
        atCmdPos = false;
        prevSemi = false;
      } else if (t.v === "|") {
        if (top && top.state === "pattern")
          marks.add(i);
        atCmdPos = true;
        prevSemi = false;
      } else if (t.v === ";") {
        if (top && top.state === "body" && prevSemi)
          top.state = "pattern";
        atCmdPos = true;
        prevSemi = true;
      } else if (t.v === "&") {
        if (top && top.state === "body" && prevSemi)
          top.state = "pattern";
        atCmdPos = true;
        prevSemi = false;
      } else if (t.v === "||" || t.v === "&&" || t.v === "|&" || t.v === `
`) {
        atCmdPos = true;
        prevSemi = false;
      } else {
        atCmdPos = false;
        prevSemi = false;
      }
    } else {
      const w = t.v;
      const wasCmdPos = atCmdPos;
      if (w === "case" && wasCmdPos)
        stack.push({ state: "awaitIn" });
      else if (w === "in" && top && top.state === "awaitIn")
        top.state = "pattern";
      else if (w === "esac" && top)
        stack.pop();
      atCmdPos = wasCmdPos && CMD_INTRODUCERS.has(w);
      prevSemi = false;
    }
  }
  return marks;
}
function detectPipeToShell(toks) {
  const alt = caseAlternationPipes(toks);
  for (let i = 0;i < toks.length - 1; i++) {
    if (toks[i].op && (toks[i].v === "|" || toks[i].v === "|&") && !alt.has(i) && pipeFeedsShellInterpreter(toks, i + 1))
      return true;
  }
  return false;
}
function detectSearchExec(toks) {
  let cur = [];
  const cmds = [];
  for (const t of toks) {
    if (t.op && (t.v === "|" || t.v === "||" || t.v === "&&" || t.v === ";" || t.v === "&" || t.v === `
`)) {
      if (cur.length)
        cmds.push(cur);
      cur = [];
    } else
      cur.push(t);
  }
  if (cur.length)
    cmds.push(cur);
  for (const sc of cmds) {
    let words = sc.filter((t) => !t.op).map((t) => t.v);
    while (words.length && SUBSHELL_OPENERS.has(words[0]))
      words = words.slice(1);
    if (!words.length)
      continue;
    let i = 0;
    for (;; ) {
      const w = words[i];
      if (w === undefined)
        break;
      if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) {
        if (RG_CONFIG_ENV.test(w))
          return true;
        i++;
        continue;
      }
      const base = cmdBasename(w);
      if (ENV_SETTING_VERBS.has(base)) {
        if (words.slice(i + 1).some((a) => RG_CONFIG_ENV.test(a)))
          return true;
        break;
      }
      if (SEARCH_WRAPPERS.has(base)) {
        i++;
        while (i < words.length) {
          const a = words[i];
          if (a === "-") {
            i++;
            continue;
          }
          if (a.startsWith("-")) {
            if (/^-[uCPa]$/.test(a))
              i++;
            i++;
            continue;
          }
          if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(a)) {
            if (RG_CONFIG_ENV.test(a))
              return true;
            i++;
            continue;
          }
          break;
        }
        continue;
      }
      break;
    }
    if (i >= words.length)
      continue;
    let ai = i + 1;
    const verb = cmdBasename(words[i]);
    if (verb === "rtk") {
      let k = i + 1;
      while (k < words.length && words[k] !== "--" && words[k].startsWith("-"))
        k++;
      const sub = cmdBasename(words[k] ?? "");
      if (sub !== "rg" && sub !== "grep")
        continue;
      ai = k + 1;
    } else if (verb !== "rg")
      continue;
    for (let j = ai;j < words.length; j++) {
      const w = words[j];
      if (w === "--")
        break;
      if (/^--(?:pre|hostname-bin)(?:=|$)/.test(w))
        return true;
    }
  }
  return false;
}
function detectStartupWrite(toks) {
  for (let i = 0;i < toks.length - 1; i++) {
    if (toks[i].op && toks[i].v.includes(">") && !toks[i + 1].op && isStartupFile(toks[i + 1].v))
      return true;
  }
  let cur = [];
  const cmds = [];
  for (const t of toks) {
    if (t.op && (t.v === "|" || t.v === "||" || t.v === "&&" || t.v === ";" || t.v === "&" || t.v === `
`)) {
      if (cur.length)
        cmds.push(cur);
      cur = [];
    } else
      cur.push(t);
  }
  if (cur.length)
    cmds.push(cur);
  for (const sc of cmds) {
    const words = sc.filter((t) => !t.op).map((t) => t.v);
    if (!words.length)
      continue;
    let ci = 0;
    while (ci < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[ci]))
      ci++;
    if (ci >= words.length)
      continue;
    const cmd = cmdBasename(words[ci]);
    const args = words.slice(ci + 1);
    const nonFlag = args.filter((a) => !a.startsWith("-"));
    if (cmd === "tee") {
      if (nonFlag.some(isStartupFile))
        return true;
    } else if (cmd === "sed") {
      if (args.some((a) => /^-i/.test(a) || a.startsWith("--in-place")) && nonFlag.some(isStartupFile))
        return true;
    } else if (cmd === "cp" || cmd === "mv" || cmd === "install" || cmd === "ln") {
      if (nonFlag.length && isStartupFile(nonFlag[nonFlag.length - 1]))
        return true;
    } else if (cmd === "dd") {
      if (args.some((a) => a.startsWith("of=") && isStartupFile(a.slice(3))))
        return true;
    }
  }
  return false;
}
function structuralChecks(command, opts = {}) {
  try {
    const toks = tokenize(command);
    const pipe = detectPipeToShell(toks);
    return {
      pipeToShell: pipe && !bootstrapExempt(command, toks, opts?.trustedBootstrap ?? []),
      startupWrite: detectStartupWrite(toks),
      searchExec: detectSearchExec(toks),
      degraded: false
    };
  } catch {
    return {
      pipeToShell: PIPE_TO_SHELL_RAW.test(command),
      startupWrite: STARTUP_WRITE_RAW.test(command),
      searchExec: SEARCH_EXEC_RAW.test(command),
      degraded: true
    };
  }
}
// data/secret-patterns.json
var secret_patterns_default = {
  _doc: "SINGLE SOURCE OF TRUTH for the egress guards. Both leak-guard.ts (web egress) and command-guard.ts (Bash egress) read it via JSON.parse. CONSTRAINT: every pattern is a POSIX-ERE string that is byte-for-byte valid in BOTH `grep -E` (BSD + GNU) AND JavaScript RegExp \u2014 so use [0-9]/[A-Za-z] character classes, NOT \\d or \\s or [[:space:]] (those diverge across the two engines). \\b word boundary is supported by both. Patterns require a real key-SHAPED VALUE, not a bare prefix or the mere words, so analysis text that merely mentions a credential type does not trip them. Keep in lockstep with the shared corpus in tests/corpus.json \u2014 CI runs every case against BOTH guards.",
  outboundInvocation: "\\b(curl|wget|nc|ncat|socat|fetch)\\b",
  credentialPatterns: [
    { pattern: "sk_live_[0-9A-Za-z]{16,}", label: "Stripe live key" },
    { pattern: "sk_test_[0-9A-Za-z]{16,}", label: "Stripe test key" },
    { pattern: "sk-ant-(api|oat|admin)[0-9]+-[0-9A-Za-z_-]{20,}", label: "Anthropic key" },
    { pattern: "sk-proj-[0-9A-Za-z_-]{20,}", label: "OpenAI project key" },
    { pattern: "whsec_[0-9A-Za-z]{20,}", label: "Webhook secret" },
    { pattern: "AKIA[0-9A-Z]{16}", label: "AWS access key id" },
    { pattern: "gh[pousr]_[0-9A-Za-z]{30,}", label: "GitHub token" },
    { pattern: "xox[baprs]-[0-9A-Za-z-]{10,}", label: "Slack token" },
    { pattern: "ssh-(rsa|ed25519|dss) AAAA[0-9A-Za-z+/]{20,}", label: "SSH key body" },
    { pattern: "-----BEGIN [A-Z ]*PRIVATE KEY-----", label: "Private key block" }
  ]
};

// src/egress/patterns.ts
var LABEL_UNSAFE = /[^A-Za-z0-9 ._-]/g;
function sanitizeLabel(label) {
  const stripped = String(label ?? "credential").replace(LABEL_UNSAFE, "");
  return stripped || "credential";
}
function parsePatterns(raw) {
  try {
    const p = raw;
    if (typeof p.outboundInvocation !== "string" || !p.outboundInvocation)
      return null;
    if (!Array.isArray(p.credentialPatterns) || p.credentialPatterns.length === 0)
      return null;
    const list = p.credentialPatterns;
    if (list.some((c) => typeof c.pattern !== "string" || !c.pattern))
      return null;
    const creds = list.map((c) => [new RegExp(c.pattern), sanitizeLabel(c.label)]);
    return {
      outbound: new RegExp(p.outboundInvocation, "i"),
      creds,
      credAny: new RegExp(list.map((c) => c.pattern).join("|"))
    };
  } catch {
    return null;
  }
}
var DEFAULT_PATTERNS = parsePatterns(secret_patterns_default);
// src/egress/scanner.ts
import { spawnSync } from "child_process";
var trufflehogScanner = (text) => {
  const r = spawnSync("trufflehog", ["stdin", "--json", "--no-update", "--no-verification"], { input: text, encoding: "utf-8" });
  if (r.error)
    return "unavailable";
  return (r.stdout || "").includes('"DetectorName"') ? "found" : "clean";
};
// src/egress/notices.ts
var EGRESS_NOTICES = [
  { match: /\bcurl\b.*?(?:-d\b|--data(?:-[a-z]+)?\b|-X[ \t]*POST\b)/i, note: "curl HTTP upload (POST / --data)" },
  { match: /\bwget\b.*?--post-(?:data|file)\b/i, note: "wget HTTP upload (--post-*)" },
  { match: /\b(?:nc|ncat)\b[ \t]/i, note: "netcat / ncat connection" },
  { match: /\bsocat\b[ \t]/i, note: "socat relay" },
  { match: /\bsendmail\b/i, note: "sendmail invocation" },
  { match: /^[ \t]*(?:env|printenv)[ \t]*$/i, note: "bare environment dump" },
  { match: /^[ \t]*set[ \t]*$/i, note: "bare shell-variable dump" },
  { match: /\bpython3?[ \t]+-c\b/i, note: "inline python execution (-c)" },
  { match: /\b(?:node|ruby|perl)[ \t]+-e\b/i, note: "inline interpreter execution (-e)" }
];

// src/evaluate.ts
var FALLBACK_OUTBOUND = /\b(curl|wget|nc|ncat|socat|fetch)\b/i;
var REASONS = {
  "pipe-to-shell": "piping output into a shell interpreter (curl \u2026 | bash). Download, inspect, then run.",
  "startup-write": "writing to a shell startup file (~/.zshrc, ~/.bashrc, \u2026) is a persistence vector. If intentional, run it in your own shell.",
  "search-exec": "ripgrep's --pre / --hostname-bin run an arbitrary binary, and RIPGREP_CONFIG_PATH injects flags from a file. Search without them, or run it in your own shell.",
  "patterns-unavailable": "the secret patterns are missing or corrupt, so the egress scan can't run. Blocking as a precaution; reinstall to restore them.",
  "secret-detected": "contains a detected secret. Reference it via an environment variable instead of pasting the literal value.",
  "org-marker": "matches an internal identifier from your org egress config (hostname, IP, path, or username). Describe it generically instead.",
  "credential-shape": "contains a credential value sent via an outbound tool.",
  "mcp-server-denied": "this MCP server is denied by policy.",
  "mcp-server-not-allowed": "this MCP server is not on the allow list.",
  "mcp-input-unscannable": "MCP tool input has too many fields, is too large, or is too deeply nested to scan."
};
var block = (rule, notices, reason = REASONS[rule], detail) => ({ kind: "block", rule, reason, notices, ...detail === undefined ? {} : { detail } });
function scannerNotice() {
  return { level: "warn", code: "scanner-unavailable", message: "trufflehog not installed; secret detection degraded to regex tiers." };
}
function orgNotices(org, notices) {
  if (org?.stale)
    notices.push({ level: "warn", code: "org-stale", message: "org egress config changed since install; re-run the installer to recompile it." });
  if (org && !org.pattern && org.patternError)
    notices.push({ level: "warn", code: "org-pattern-invalid", message: "the compiled org pattern isn't a valid regex; org tier skipped." });
}
function orgHit(org, text) {
  const re = org?.pattern;
  if (!re)
    return false;
  const stateless = re.global || re.sticky ? new RegExp(re.source, re.flags.replace(/[gy]/g, "")) : re;
  return stateless.test(text);
}
function evaluateBash(command, ctx = {}) {
  const notices = [];
  if (!command)
    return { kind: "allow", notices };
  const s = structuralChecks(command, { trustedBootstrap: ctx.trustedBootstrap });
  if (s.degraded)
    notices.push({ level: "warn", code: "parse-degraded", message: "command too complex to parse precisely; strict structural checks applied." });
  if (s.pipeToShell)
    return block("pipe-to-shell", notices);
  if (s.startupWrite)
    return block("startup-write", notices);
  if (s.searchExec)
    return block("search-exec", notices);
  if (ctx.scanSecrets !== false) {
    const patterns = ctx.patterns === undefined ? DEFAULT_PATTERNS : ctx.patterns;
    if (!patterns) {
      if (FALLBACK_OUTBOUND.test(command))
        return block("patterns-unavailable", notices);
    } else if (patterns.outbound.test(command)) {
      const hit = (ctx.scanner ?? trufflehogScanner)(command);
      if (hit === "unavailable")
        notices.push(scannerNotice());
      if (hit === "found")
        return block("secret-detected", notices);
      orgNotices(ctx.org, notices);
      if (orgHit(ctx.org, command))
        return block("org-marker", notices);
      for (const [re, label] of patterns.creds) {
        if (re.test(command))
          return block("credential-shape", notices, `credential exfiltration: ${label} sent via an outbound tool.`, label);
      }
    }
  }
  for (const { match, note } of EGRESS_NOTICES) {
    if (match.test(command)) {
      notices.push({ level: "alert", code: "egress-alert", message: `${note} (allowed).` });
      break;
    }
  }
  return { kind: "allow", notices };
}
function evaluateWebQuery(text, ctx = {}) {
  const notices = [];
  if (!text || ctx.scanSecrets === false)
    return { kind: "allow", notices };
  const patterns = ctx.patterns === undefined ? DEFAULT_PATTERNS : ctx.patterns;
  if (!patterns)
    return block("patterns-unavailable", notices);
  const hit = (ctx.scanner ?? trufflehogScanner)(text);
  if (hit === "unavailable")
    notices.push(scannerNotice());
  if (hit === "found")
    return block("secret-detected", notices);
  orgNotices(ctx.org, notices);
  if (orgHit(ctx.org, text))
    return block("org-marker", notices);
  if (patterns.credAny.test(text))
    return block("credential-shape", notices, "contains a token or key value.");
  return { kind: "allow", notices };
}
// src/util.ts
function isPlainObject(v) {
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
}

// src/mcp.ts
var MAX_DEPTH = 32;
var MAX_LEAVES = 200000;
var MAX_CHARS = 1e6;
function mcpServerOf(tool) {
  if (!tool.startsWith("mcp__"))
    return null;
  const rest = tool.slice(5);
  const i = rest.indexOf("__");
  return i > 0 ? rest.slice(0, i) : null;
}
function flatten(input) {
  const out = [];
  let chars = 0;
  const onPath = new WeakSet;
  const done = new WeakSet;
  function pushLeaf(v) {
    out.push(v);
    chars += v.length;
    return out.length > MAX_LEAVES || chars > MAX_CHARS;
  }
  function walk(v, depth) {
    if (depth > MAX_DEPTH)
      return true;
    if (typeof v === "string")
      return pushLeaf(v);
    if (v === null || typeof v !== "object")
      return false;
    const obj = v;
    if (onPath.has(obj))
      return true;
    if (done.has(obj))
      return false;
    if (Array.isArray(obj)) {
      onPath.add(obj);
      for (const x of obj) {
        if (walk(x, depth + 1)) {
          onPath.delete(obj);
          return true;
        }
      }
      onPath.delete(obj);
      done.add(obj);
      return false;
    }
    if (!isPlainObject(obj))
      return true;
    onPath.add(obj);
    for (const [k, val] of Object.entries(obj)) {
      if (pushLeaf(k)) {
        onPath.delete(obj);
        return true;
      }
      if (walk(val, depth + 1)) {
        onPath.delete(obj);
        return true;
      }
    }
    onPath.delete(obj);
    done.add(obj);
    return false;
  }
  return walk(input, 0) ? null : out;
}
var block2 = (rule, reason, notices = []) => ({ kind: "block", rule, reason, notices });
function evaluateMcpInput(tool, input, ctx = {}) {
  const server = mcpServerOf(tool);
  const serverLower = server?.toLowerCase();
  const deny = (ctx.mcp?.deny ?? []).map((s) => s.toLowerCase());
  const allow = (ctx.mcp?.allow ?? []).map((s) => s.toLowerCase());
  if (serverLower && deny.includes(serverLower))
    return block2("mcp-server-denied", `MCP server "${server}" is denied by policy.`);
  if (serverLower && allow.length > 0 && !allow.includes(serverLower))
    return block2("mcp-server-not-allowed", `MCP server "${server}" is not on the allow list.`);
  if (!serverLower && allow.length > 0)
    return block2("mcp-server-not-allowed", "MCP tool name has no server segment; blocked by the allow list.");
  if (ctx.scanSecrets === false)
    return { kind: "allow", notices: [] };
  const leaves = flatten(input);
  if (leaves === null)
    return block2("mcp-input-unscannable", "MCP tool input has too many fields, is too large, or is too deeply nested to scan.");
  return evaluateWebQuery(leaves.join(`
`), ctx);
}
// src/rtk/rewrite.ts
var ENV_PREFIX = /^([A-Za-z_]\w*=[A-Za-z0-9_./:@%+,=~-]* +)+/;
var ALREADY_RTK = /^(\S*\/)?rtk\s/;
var HELP_FLAG = /(?:^|\s)(?:-h|--help)(?=\s|$)/;
function supportedVersion(version) {
  const m = version.trim().match(/^rtk (\d+)\.(\d+)\.(\d+)$/);
  return !!m && (Number(m[1]) > 0 || Number(m[2]) >= 49);
}
var CRED_PATH = /\.(ssh|gnupg|aws|azure|kube|pypirc|netrc|electrum|ethereum)($|[^\w])|\.npmrc($|[^\w])|\/gcloud\/|\.docker\/config\.json|\.gem\/credentials|\.git-credentials|\/\.config\/gh\/|Library\/Keychains\/|Application Support\/Electrum|\/Electrum\/|\/Exodus\/|Library\/Ethereum\/|\/[Mm]eta[Mm]ask\/|\/[Pp]hantom\/|\/[Ss]olflare\/|(^|[^\w.])\.env($|[^\w])/;
var leadWord = (cmd) => cmd.trimStart().split(/\s+/, 1)[0] ?? "";
var startsWithWord = (cmd, word) => cmd === word || cmd.startsWith(word + " ");
var withArgs = (cmd, word) => cmd.startsWith(word + " ");
var front = (body) => "rtk " + body;
function subcommand(body, prog, opts = {}) {
  let rest = body.slice(prog.length).trimStart();
  for (;; ) {
    const tok = rest.split(/\s+/, 1)[0] ?? "";
    if (!tok)
      break;
    if (opts.valued?.test(tok)) {
      const after = rest.slice(tok.length).trimStart();
      rest = after.slice((after.split(/\s+/, 1)[0] ?? "").length).trimStart();
      continue;
    }
    if (/^--[a-z][\w-]*=/.test(tok) || opts.longFlags?.test(tok)) {
      rest = rest.slice(tok.length).trimStart();
      continue;
    }
    break;
  }
  return rest.split(/\s+/, 1)[0] ?? "";
}
var GIT_SUBCMDS = new Set([
  "status",
  "diff",
  "log",
  "add",
  "commit",
  "push",
  "pull",
  "branch",
  "fetch",
  "stash",
  "show"
]);
var CARGO_SUBCMDS = new Set(["test", "build", "clippy", "check", "install", "fmt"]);
var DOCKER_SUBCMDS = new Set(["ps", "images", "logs", "run", "build", "exec"]);
var DOCKER_COMPOSE_SUBCMDS = new Set(["ps", "logs", "build"]);
var KUBECTL_SUBCMDS = new Set(["get", "logs", "describe", "apply"]);
var RULES = [
  (b) => {
    if (!startsWithWord(leadWord(b), "git"))
      return null;
    const sub = subcommand(b, "git", {
      valued: /^-[Cc]$/,
      longFlags: /^--(no-pager|no-optional-locks|bare|literal-pathspecs)$/
    });
    return GIT_SUBCMDS.has(sub) ? front(b) : null;
  },
  (b) => {
    const sub = subcommand(b, "gh");
    return startsWithWord(leadWord(b), "gh") && ["pr", "issue", "run", "api", "release"].includes(sub) ? front(b) : null;
  },
  (b) => {
    if (!startsWithWord(leadWord(b), "cargo"))
      return null;
    let rest = b.slice("cargo".length).trimStart();
    if (rest.startsWith("+"))
      rest = rest.slice((rest.split(/\s+/, 1)[0] ?? "").length).trimStart();
    return CARGO_SUBCMDS.has(rest.split(/\s+/, 1)[0] ?? "") ? front(b) : null;
  },
  (b) => {
    if (!withArgs(b, "cat"))
      return null;
    if (CRED_PATH.test(b))
      return null;
    if (/(?:^|\s)["']?-/.test(b.slice(4)))
      return null;
    return "rtk read " + b.slice("cat".length).trimStart();
  },
  (b) => (withArgs(b, "grep") || withArgs(b, "rg")) && !CRED_PATH.test(b) ? front(b) : null,
  (b) => startsWithWord(leadWord(b), "ls") ? front(b) : null,
  (b) => startsWithWord(leadWord(b), "tree") ? front(b) : null,
  (b) => withArgs(b, "find") ? front(b) : null,
  (b) => withArgs(b, "diff") ? front(b) : null,
  (b) => {
    const m = b.match(/^vitest\s+run(\s.*|$)/);
    return m ? "rtk vitest run" + m[1] : null;
  },
  (b) => startsWithWord(b, "npm test") ? "rtk npm test" + b.slice("npm test".length) : null,
  (b) => {
    const m = b.match(/^npm\s+run\s+(.+)$/);
    return m ? front(b) : null;
  },
  (b) => {
    const m = b.match(/^tsc(\s.*|$)/);
    return m ? "rtk tsc" + m[1] : null;
  },
  (b) => {
    const m = b.match(/^eslint(\s.*|$)/);
    return m ? "rtk lint" + m[1] : null;
  },
  (b) => {
    const m = b.match(/^prettier(\s.*|$)/);
    return m ? "rtk prettier" + m[1] : null;
  },
  (b) => {
    const m = b.match(/^prisma(\s.*|$)/);
    return m ? "rtk prisma" + m[1] : null;
  },
  (b) => {
    if (!startsWithWord(leadWord(b), "docker"))
      return null;
    if (/^docker\s+compose($|\s)/.test(b)) {
      const sub = b.replace(/^docker\s+compose\s*/, "").split(/\s+/, 1)[0] ?? "";
      return DOCKER_COMPOSE_SUBCMDS.has(sub) ? front(b) : null;
    }
    const sub = subcommand(b, "docker", {
      valued: /^(-H|--context|--config)$/
    });
    return DOCKER_SUBCMDS.has(sub) ? front(b) : null;
  },
  (b) => {
    if (!startsWithWord(leadWord(b), "kubectl"))
      return null;
    const sub = subcommand(b, "kubectl", {
      valued: /^(--context|--kubeconfig|--namespace|-n)$/
    });
    return KUBECTL_SUBCMDS.has(sub) ? front(b) : null;
  },
  (b) => withArgs(b, "curl") ? front(b) : null,
  (b) => withArgs(b, "wget") ? front(b) : null,
  (b) => {
    const sub = subcommand(b, "pnpm");
    return startsWithWord(leadWord(b), "pnpm") && ["list", "ls", "outdated"].includes(sub) ? front(b) : null;
  },
  (b) => startsWithWord(leadWord(b), "pytest") ? front(b) : null,
  (b) => {
    const sub = subcommand(b, "ruff");
    return startsWithWord(leadWord(b), "ruff") && ["check", "format"].includes(sub) ? front(b) : null;
  },
  (b) => {
    const sub = subcommand(b, "pip");
    return startsWithWord(leadWord(b), "pip") && ["list", "outdated", "install", "show"].includes(sub) ? front(b) : null;
  },
  (b) => startsWithWord(leadWord(b), "mypy") ? front(b) : null,
  (b) => {
    if (!startsWithWord(leadWord(b), "go"))
      return null;
    const sub = b.slice("go".length).trimStart().split(/\s+/, 1)[0] ?? "";
    return ["test", "build", "vet"].includes(sub) ? front(b) : null;
  },
  (b) => startsWithWord(leadWord(b), "golangci-lint") ? front(b) : null,
  (b) => withArgs(b, "aws") ? front(b) : null,
  (b) => startsWithWord(leadWord(b), "psql") ? front(b) : null
];
function rewrite(command) {
  if (ALREADY_RTK.test(command) || /[|&;<>`$(){}\\\n\r#]/.test(command))
    return null;
  if (HELP_FLAG.test(command))
    return null;
  const prefix = command.match(ENV_PREFIX)?.[0] ?? "";
  if (/(^| )PATH=/.test(prefix))
    return null;
  const body = command.slice(prefix.length);
  for (const rule of RULES) {
    const out = rule(body);
    if (out !== null)
      return prefix + out;
  }
  return null;
}
// src/aitc/detect.ts
import { existsSync, readdirSync, readFileSync } from "fs";
import { isAbsolute, join, resolve } from "path";
var DEFAULT_ROOTS = {
  claude: [".claude"],
  codex: [".codex"],
  antigravity: [],
  grok: []
};
var AITC_AKA_MARKETPLACES = new Set(["akasecurity", "ai-tc"]);
var isAitcClaudePlugin = (name, marketplace) => name === "ai-tc" || name === "aka" && AITC_AKA_MARKETPLACES.has(marketplace);
function readJson(readFile, p) {
  const raw = readFile(p);
  if (raw === null)
    return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}
var isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
function enabledClaudePlugins(root, readFile) {
  const registry = readJson(readFile, join(root, "plugins/installed_plugins.json"));
  if (!isObject(registry) || !isObject(registry.plugins))
    return new Set;
  const settings = readJson(readFile, join(root, "settings.json"));
  const enabled = isObject(settings) && isObject(settings.enabledPlugins) ? settings.enabledPlugins : {};
  return new Set(Object.keys(registry.plugins).filter((k) => enabled[k] === true));
}
function projectDisabledClaudePlugins(projectDir, readFile) {
  const disabled = new Set;
  for (const file of ["settings.json", "settings.local.json"]) {
    const settings = readJson(readFile, join(projectDir, ".claude", file));
    if (!isObject(settings) || !isObject(settings.enabledPlugins))
      continue;
    for (const [k, v] of Object.entries(settings.enabledPlugins)) {
      if (v === false)
        disabled.add(k);
    }
  }
  return disabled;
}
function detectAitc(harness, opts) {
  const exists = opts.exists ?? existsSync;
  const readdir = opts.readdir ?? ((p) => {
    try {
      return readdirSync(p);
    } catch {
      return [];
    }
  });
  const readFile = opts.readFile ?? ((p) => {
    try {
      return readFileSync(p, "utf-8");
    } catch {
      return null;
    }
  });
  const home = isAbsolute(opts.home) ? opts.home : null;
  const rawRoots = opts.roots !== undefined ? opts.roots : home ? DEFAULT_ROOTS[harness].map((r) => join(home, r)) : [];
  const roots = [...new Set(rawRoots.filter((r) => !!r && isAbsolute(r)).map((r) => resolve(r)))];
  const markers = [];
  if (harness === "claude") {
    const projectDir = opts.projectDir !== undefined && isAbsolute(opts.projectDir) ? resolve(opts.projectDir) : null;
    const projectDisabled = projectDir ? projectDisabledClaudePlugins(projectDir, readFile) : new Set;
    for (const r of roots) {
      const cache = join(r, "plugins/cache");
      let enabled;
      for (const marketplace of readdir(cache)) {
        const mk = join(cache, marketplace);
        for (const d of readdir(mk)) {
          if (!isAitcClaudePlugin(d, marketplace))
            continue;
          enabled ??= enabledClaudePlugins(r, readFile);
          const key = `${d}@${marketplace}`;
          if (enabled.has(key) && !projectDisabled.has(key))
            markers.push(join(mk, d));
        }
      }
    }
  } else if (harness === "codex") {
    for (const r of roots) {
      const cache = join(r, "plugins/cache");
      for (const m of readdir(cache)) {
        const p = join(cache, m, "aka-codex");
        if (exists(p))
          markers.push(p);
      }
    }
  } else if (harness === "antigravity" && home) {
    const p = join(home, ".gemini/config/plugins/aka-antigravity");
    if (exists(p))
      markers.push(p);
  }
  const uniqueMarkers = [...new Set(markers)];
  return {
    present: uniqueMarkers.length > 0,
    harness,
    markers: uniqueMarkers,
    sharedState: home ? exists(join(home, ".aka/data/aka.db")) : false
  };
}
// src/aitc/policy.ts
var AITC_HOOKED_TOOLS = {
  claude: ["Bash", "Edit", "Write", "WebFetch", "MultiEdit", "NotebookEdit", "Task", "Agent"],
  codex: ["Bash", "apply_patch"],
  antigravity: [],
  grok: []
};
var AITC_POST_HOOKED_TOOLS = {
  claude: ["Bash", "Read", "WebFetch"],
  codex: ["Bash", "apply_patch"],
  antigravity: [],
  grok: []
};
function aitcHooks(harness, tool) {
  const hooked = AITC_HOOKED_TOOLS[harness];
  return hooked.length === 0 || hooked.includes(tool) || tool.startsWith("mcp__");
}
function aitcPostHooks(harness, tool) {
  const hooked = AITC_POST_HOOKED_TOOLS[harness];
  return hooked.length === 0 || hooked.includes(tool);
}
function coexistencePolicy(status) {
  if (!status.present) {
    return {
      scanSecrets: () => true,
      redact: true,
      auditLog: true,
      statusline: true,
      allowRewrite: () => true,
      redactOutput: () => true
    };
  }
  const free = (tool) => !aitcHooks(status.harness, tool);
  return {
    scanSecrets: free,
    redact: false,
    auditLog: false,
    statusline: false,
    allowRewrite: free,
    redactOutput: (tool) => !aitcPostHooks(status.harness, tool)
  };
}
// src/prompt.ts
var INJECTION_MARKERS = [
  /\bignore (?:all |any |the )?(?:previous|prior|above) (?:instructions|prompts?|rules)\b/i,
  /\bdisregard (?:all |any |the )?(?:previous|prior|above) (?:instructions|rules)\b/i,
  /\byou are now (?:in |a |an )?(?:developer|dan|jailbreak|unrestricted)\b/i,
  /^\s*(?:\[system\]|<system>)/im,
  /^\s*system:\s*(?:you are|ignore|disregard|new instructions|from now on)\b/im,
  /\bnew (?:system )?instructions:\s/i
];
var EXFIL_VERB = /\b(?:send|post|upload|forward|paste|share|email|exfiltrate|curl|wget)\b/i;
var B64 = /[A-Za-z0-9+/]{40,}={0,2}/g;
var HEX = /\b(?:[0-9a-fA-F]{2}){24,}\b/g;
var SHELLISH = /\b(?:bash|sh|zsh|curl|wget|nc|python3?\s+-c|powershell)\b/;
var BLOB_SCAN_LIMIT = 200000;
var MAX_BLOB_DECODES = 50;
var warn = (code, message) => ({ level: "warn", code, message });
var credAnyGlobalCache = new WeakMap;
function credAnyGlobal(pats) {
  let re = credAnyGlobalCache.get(pats);
  if (!re) {
    re = new RegExp(pats.credAny.source, "g");
    credAnyGlobalCache.set(pats, re);
  }
  return re;
}
function decodesToShell(blob, enc) {
  try {
    const s = Buffer.from(blob, enc).toString("utf8");
    if (/[^\x09\x0a\x0d\x20-\x7e]/.test(s))
      return false;
    return SHELLISH.test(s);
  } catch {
    return false;
  }
}
function scanPrompt(text, opts = {}) {
  const out = [];
  if (INJECTION_MARKERS.some((re) => re.test(text))) {
    out.push(warn("prompt-injection-marker", "prompt contains a prompt-injection marker."));
  }
  if (opts.injectionOnly)
    return out;
  const pats = opts.patterns === undefined ? DEFAULT_PATTERNS : opts.patterns;
  if (pats && pats.credAny.test(text) && EXFIL_VERB.test(text.replace(credAnyGlobal(pats), " "))) {
    out.push(warn("prompt-secret-exfil", "prompt pairs a credential value with a send/post/upload instruction."));
  }
  const scanRegion = text.length > BLOB_SCAN_LIMIT ? text.slice(0, BLOB_SCAN_LIMIT) : text;
  const blobs = [];
  for (const m of scanRegion.matchAll(B64)) {
    blobs.push([m[0], "base64"]);
    if (blobs.length >= MAX_BLOB_DECODES)
      break;
  }
  if (blobs.length < MAX_BLOB_DECODES) {
    for (const m of scanRegion.matchAll(HEX)) {
      blobs.push([m[0], "hex"]);
      if (blobs.length >= MAX_BLOB_DECODES)
        break;
    }
  }
  if (blobs.some(([b, e]) => decodesToShell(b, e))) {
    out.push(warn("prompt-encoded-shell", "prompt contains an encoded blob that decodes to a shell command."));
  }
  return out;
}
// src/redact.ts
var DEFAULT_MAX_CHARS = 5000000;
var DEFAULT_MAX_DEPTH = 64;
function isEscapedAt(source, pos) {
  let backslashes = 0;
  for (let i = pos - 1;i >= 0 && source[i] === "\\"; i--)
    backslashes++;
  return backslashes % 2 === 1;
}
function lazyTail(source) {
  const brace = /\{(\d+),\}$/.exec(source);
  if (brace && !isEscapedAt(source, brace.index)) {
    return `${source.slice(0, brace.index)}{${brace[1]},}?`;
  }
  const last = source[source.length - 1];
  if ((last === "+" || last === "*") && !isEscapedAt(source, source.length - 1)) {
    return `${source}?`;
  }
  return source;
}
var globalCredsCache = new WeakMap;
function globalCreds(pats) {
  let cached = globalCredsCache.get(pats);
  if (!cached) {
    cached = pats.creds.map(([re, label]) => [new RegExp(lazyTail(re.source), re.flags.includes("g") ? re.flags : re.flags + "g"), label]);
    globalCredsCache.set(pats, cached);
  }
  return cached;
}
var TOKEN_CHAR_CLASS = "A-Za-z0-9_\\-+/=.";
var TOKEN_RUN = new RegExp(`[${TOKEN_CHAR_CLASS}]+`, "g");
function tokenRuns(text) {
  const runs = [];
  TOKEN_RUN.lastIndex = 0;
  let m;
  while (m = TOKEN_RUN.exec(text))
    runs.push({ start: m.index, end: m.index + m[0].length });
  return runs;
}
function runContaining(runs, pos) {
  let lo = 0;
  let hi = runs.length - 1;
  while (lo <= hi) {
    const mid = lo + hi >> 1;
    const r = runs[mid];
    if (pos < r.start)
      hi = mid - 1;
    else if (pos >= r.end)
      lo = mid + 1;
    else
      return r;
  }
  return null;
}
var PEM_CAP = 65536;
var PEM_HEADER = /-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----/;
var PEM_BODY_LINE = /^[A-Za-z0-9+/=]*$/;
var PEM_HEADER_LINE = /^(?:Proc-Type|DEK-Info):/;
function extendPemBodyFallback(text, headerEnd, capEnd) {
  let pos = headerEnd;
  if (text[pos] === "\r")
    pos++;
  if (text[pos] === `
`)
    pos++;
  let blanksSeen = 0;
  while (pos < capEnd) {
    const nl = text.indexOf(`
`, pos);
    if (nl === -1 || nl >= capEnd)
      break;
    let line = text.slice(pos, nl);
    if (line.endsWith("\r"))
      line = line.slice(0, -1);
    if (line.length === 0) {
      if (++blanksSeen > 1)
        break;
    } else if (!PEM_BODY_LINE.test(line) && !PEM_HEADER_LINE.test(line)) {
      break;
    }
    pos = nl + 1;
  }
  return pos;
}
var PEM_FOOTER_GLOBAL = /-----END ([A-Z0-9 ]*)PRIVATE KEY-----/g;
var PEM_MAX_HEADERS = 1e4;
function footerEndsByType(text) {
  const out = new Map;
  for (const m of text.matchAll(PEM_FOOTER_GLOBAL)) {
    const end = m.index + m[0].length;
    const arr = out.get(m[1]);
    if (arr)
      arr.push(end);
    else
      out.set(m[1], [end]);
  }
  return out;
}
function lastAtMost(xs, max) {
  let lo = 0, hi = xs.length - 1, best = -1;
  while (lo <= hi) {
    const mid = lo + hi >> 1;
    if (xs[mid] <= max) {
      best = xs[mid];
      lo = mid + 1;
    } else
      hi = mid - 1;
  }
  return best;
}
function extendPemBlock(text, start, headerEnd, matchText, footerEnds) {
  const capEnd = Math.min(text.length, start + PEM_CAP);
  const headerMatch = footerEnds && PEM_HEADER.exec(matchText);
  if (headerMatch) {
    const footerLen = `-----END ${headerMatch[1]}PRIVATE KEY-----`.length;
    const ends = footerEnds.get(headerMatch[1]);
    if (ends) {
      const end = lastAtMost(ends, capEnd);
      if (end !== -1 && end - footerLen >= headerEnd)
        return end;
    }
  }
  return extendPemBodyFallback(text, headerEnd, capEnd);
}
function collectRawMatches(text, patterns) {
  const out = [];
  let footerEnds;
  let pemHeaders = 0;
  for (const [re, label] of globalCreds(patterns)) {
    for (const m of text.matchAll(re)) {
      const start = m.index;
      const headerEnd = start + m[0].length;
      if (PEM_HEADER.test(m[0])) {
        footerEnds ??= footerEndsByType(text);
        const lookup = ++pemHeaders <= PEM_MAX_HEADERS ? footerEnds : null;
        out.push({ start, end: extendPemBlock(text, start, headerEnd, m[0], lookup), label, rightNoExtend: true });
      } else {
        out.push({ start, end: headerEnd, label });
      }
    }
  }
  return out;
}
function mergeSpans(text, raw) {
  const allLabels = new Set;
  const runs = tokenRuns(text);
  const extended = raw.map((m) => {
    allLabels.add(m.label);
    const leftRun = runContaining(runs, m.start);
    const rightRun = m.rightNoExtend ? null : runContaining(runs, m.end);
    return {
      start: leftRun ? Math.min(m.start, leftRun.start) : m.start,
      end: rightRun ? Math.max(m.end, rightRun.end) : m.end,
      label: m.label,
      earliestStart: m.start
    };
  });
  extended.sort((a, b) => a.start - b.start || a.earliestStart - b.earliestStart);
  const merged = [];
  for (const span of extended) {
    const last = merged[merged.length - 1];
    if (last && span.start <= last.end) {
      last.end = Math.max(last.end, span.end);
      if (span.earliestStart < last.earliestStart) {
        last.label = span.label;
        last.earliestStart = span.earliestStart;
      }
    } else {
      merged.push({ ...span });
    }
  }
  return { merged, allLabels };
}
function redactText(text, patterns = DEFAULT_PATTERNS) {
  if (!patterns)
    return { text, count: 0, labels: [] };
  const raw = collectRawMatches(text, patterns);
  if (raw.length === 0)
    return { text, count: 0, labels: [] };
  const { merged, allLabels } = mergeSpans(text, raw);
  const parts = [];
  let cursor = 0;
  for (const span of merged) {
    parts.push(text.slice(cursor, span.start), `[REDACTED:${span.label}]`);
    cursor = span.end;
  }
  parts.push(text.slice(cursor));
  return { text: parts.join(""), count: merged.length, labels: [...allLabels] };
}
var warn2 = (code, message) => ({ level: "warn", code, message });
function redactValue(value, patterns = DEFAULT_PATTERNS, limits = {}) {
  if (!patterns)
    return { value, count: 0, labels: [], truncatedScan: false };
  const maxChars = limits.maxChars ?? DEFAULT_MAX_CHARS;
  const maxDepth = limits.maxDepth ?? DEFAULT_MAX_DEPTH;
  let count = 0;
  const labels = new Set;
  let chars = 0;
  let aborted = false;
  let sawNonPlain = false;
  const onPath = new WeakSet;
  const done = new WeakMap;
  function redactString(s) {
    chars += s.length;
    if (chars > maxChars) {
      aborted = true;
      return { value: s, changed: false };
    }
    const r = redactText(s, patterns);
    if (r.count > 0) {
      count += r.count;
      for (const l of r.labels)
        labels.add(l);
    }
    return { value: r.text, changed: r.count > 0 };
  }
  function walk(v, depth) {
    if (aborted)
      return { value: v, changed: false };
    if (typeof v === "string")
      return redactString(v);
    if (v === null || typeof v !== "object")
      return { value: v, changed: false };
    if (depth > maxDepth) {
      aborted = true;
      return { value: v, changed: false };
    }
    const obj = v;
    const cached = done.get(obj);
    if (cached)
      return cached;
    if (onPath.has(obj)) {
      aborted = true;
      return { value: v, changed: false };
    }
    if (Array.isArray(obj)) {
      onPath.add(obj);
      let changed = false;
      const out = [];
      for (const item of obj) {
        const r = walk(item, depth + 1);
        if (aborted) {
          onPath.delete(obj);
          return { value: v, changed: false };
        }
        out.push(r.value);
        changed = changed || r.changed;
      }
      onPath.delete(obj);
      const result = { value: changed ? out : obj, changed };
      done.set(obj, result);
      return result;
    }
    if (!isPlainObject(obj)) {
      sawNonPlain = true;
      const result = { value: obj, changed: false };
      done.set(obj, result);
      return result;
    }
    onPath.add(obj);
    let changed = false;
    const out = Object.create(null);
    for (const [k, val] of Object.entries(obj)) {
      const kr = redactString(k);
      if (aborted) {
        onPath.delete(obj);
        return { value: v, changed: false };
      }
      const vr = walk(val, depth + 1);
      if (aborted) {
        onPath.delete(obj);
        return { value: v, changed: false };
      }
      let finalKey = kr.value;
      if (Object.prototype.hasOwnProperty.call(out, finalKey)) {
        let n = 2;
        while (Object.prototype.hasOwnProperty.call(out, `${finalKey}#${n}`))
          n++;
        finalKey = `${finalKey}#${n}`;
        changed = true;
      }
      out[finalKey] = vr.value;
      changed = changed || kr.changed || vr.changed;
    }
    onPath.delete(obj);
    const result = { value: changed ? out : obj, changed };
    done.set(obj, result);
    return result;
  }
  const top = walk(value, 0);
  if (aborted)
    return { value, count: 0, labels: [], truncatedScan: true };
  return { value: top.value, count, labels: [...labels], truncatedScan: sawNonPlain };
}
function injectionMarkers(text) {
  if (INJECTION_MARKERS.some((re) => re.test(text))) {
    return [warn2("output-injection-marker", "output contains a prompt-injection marker.")];
  }
  return [];
}
// src/audit.ts
var KEY_ORDER = ["ts", "kit", "harness", "hook", "tool", "kind", "rule", "detail", "snippet"];
var SANITIZED_FIELD_MAX = { snippet: 200, detail: 200, rule: 100, tool: 100, hook: 100 };
var SANITIZED_FIELDS = new Set(Object.keys(SANITIZED_FIELD_MAX));
var KIND_VALUES = new Set(["block", "alert", "redact", "integrity", "prompt"]);
var TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$/;
var NAME_RE = /^[a-z0-9-]{1,32}$/;
function validKind(v) {
  return typeof v === "string" && KIND_VALUES.has(v) ? v : "alert";
}
function validTs(v) {
  return typeof v === "string" && TS_RE.test(v) ? v : new Date().toISOString();
}
function validName(v) {
  return typeof v === "string" && NAME_RE.test(v) ? v : "unknown";
}
var REDACTED_MARKER = /\[REDACTED:[^\]]*\]/g;
function truncateSafely(s, max) {
  if (s.length <= max)
    return s;
  for (const m of s.matchAll(REDACTED_MARKER)) {
    const start = m.index;
    const end = start + m[0].length;
    if (start < max && max < end)
      return s.slice(0, start);
  }
  return s.slice(0, max);
}
function toStringSafe(v) {
  if (typeof v === "string")
    return v;
  try {
    const j = JSON.stringify(v);
    if (typeof j === "string")
      return j;
  } catch {}
  try {
    return String(v);
  } catch {
    return "[unrepresentable]";
  }
}
function sanitize(s, patterns, max) {
  const redacted = patterns === null ? s : redactText(s, patterns).text;
  return truncateSafely(redacted, max);
}
function formatAuditLine(event, patterns = DEFAULT_PATTERNS) {
  try {
    const out = {};
    for (const key of KEY_ORDER) {
      const value = event[key];
      if (key === "ts") {
        out.ts = validTs(value);
        continue;
      }
      if (key === "kind") {
        out.kind = validKind(value);
        continue;
      }
      if (key === "kit" || key === "harness") {
        out[key] = validName(value);
        continue;
      }
      if (value === undefined)
        continue;
      if (SANITIZED_FIELDS.has(key)) {
        const field = key;
        out[key] = sanitize(toStringSafe(value), patterns, SANITIZED_FIELD_MAX[field]);
      } else {
        out[key] = value;
      }
    }
    return `${JSON.stringify(out)}
`;
  } catch {
    return `${JSON.stringify({ ts: new Date().toISOString(), kind: "alert", detail: "unformattable event" })}
`;
  }
}

// src/index.ts
var VERSION = version;
export {
  AITC_HOOKED_TOOLS,
  AITC_POST_HOOKED_TOOLS,
  DEFAULT_PATTERNS,
  INJECTION_MARKERS,
  VERSION,
  coexistencePolicy,
  detectAitc,
  evaluateBash,
  evaluateMcpInput,
  evaluateWebQuery,
  formatAuditLine,
  injectionMarkers,
  mcpServerOf,
  parsePatterns,
  redactText,
  redactValue,
  rewrite,
  scanPrompt,
  structuralChecks,
  supportedVersion,
  trufflehogScanner
};

# PostToolUse payload fixtures

These fixtures are real `PostToolUse` hook stdin captured from a live `claude -p` run
(haiku model, throwaway `CLAUDE_CONFIG_DIR`, no real profile touched), with all content
replaced by harmless synthetic text. Session ids, the transcript path, and `cwd` are
replaced with neutral placeholders (`/tmp/example/...`). The JSON shape — key names,
nesting, and value types — is unchanged from the real capture.

Every capture shares this envelope:

```
session_id, transcript_path, cwd, prompt_id, permission_mode,
hook_event_name: "PostToolUse", tool_name, tool_input, tool_response,
tool_use_id, duration_ms
```

## Where the text lives, per tool

- **Read** (`Read.json`) — `tool_response` is an object: `{ type: "text", file: { filePath,
  content, numLines, startLine, totalLines } }`. The file text is at
  `tool_response.file.content`, a plain string.
- **WebFetch** (`WebFetch.json`) — `tool_response` is an object: `{ bytes, code, codeText,
  result, durationMs, url }`. The text a redaction hook cares about is
  `tool_response.result`, a plain string — WebFetch already runs the fetched page through
  a summarizing pass before the hook sees it, so `result` is prose, not raw HTML.
- **WebSearch** (`WebSearch.json`) — `tool_response` is an object: `{ query, results,
  durationSeconds, searchCount }`. `tool_response.results` is an array whose first element
  is `{ tool_use_id, content: [{ title, url }, ...] }` (the raw hit list — titles and URLs
  only, no body text) and whose second element is a plain string: the model's own prose
  synopsis of those hits. Both belong to `tool_response`, so a hook has to look at both the
  URL list and the trailing synopsis string.
- **mcp\_\_\*** (`mcp.json`) — `tool_response` is an **array** directly, not wrapped in a
  `{ content: [...] }` object: `[{ type: "text", text }, ...]`. This matches the raw MCP
  `tools/call` result content array. There is also a top-level `mcp_server: { name,
  source }` field alongside the usual envelope, absent for built-in tools.

So the text a post-guard redaction pass needs to scan is: `tool_response.file.content`
(Read), `tool_response.result` (WebFetch), `tool_response.results[0].content[*].url` +
`tool_response.results[1]` (WebSearch), and each `tool_response[*].text` (mcp).

## Which output field the hook returns

Quoted from the hook documentation embedded in the installed `claude` binary
(`claude` 2.1.283, extracted via `strings` on the binary and cross-checked against the
Hook JSON Output section of `claude --help`'s embedded hooks reference):

> Replaces the tool output before it is sent to the model

That is `hookSpecificOutput.updatedToolOutput` — a string, and it is the field to use for
all built-in tools (`Read`, `WebFetch`, `WebSearch`, `Bash`, ...).

> Replaces the output for MCP tools only. Prefer updatedToolOutput, which works for all
> tools

That is `hookSpecificOutput.updatedMCPToolOutput`, documented as MCP-only and secondary to
`updatedToolOutput`. In both cases the field sits under `hookSpecificOutput`, which must
also carry `hookEventName: "PostToolUse"`, per the binary's own hooks reference:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "updatedToolOutput": "...",
    "updatedMCPToolOutput": "..."
  }
}
```

Practical reading for a post-guard hook: return `updatedToolOutput` for `Read`, `WebFetch`,
and `WebSearch`; for `mcp__*` tools, `updatedMCPToolOutput` is the one that actually
replaces the array-shaped `tool_response` shown above. If a hook returns an
`updatedToolOutput` whose shape doesn't match the tool's real output shape, the binary
rejects the rewrite and falls back to the original output (observed in the binary's own
strings as `"PostToolUse hook returned updatedToolOutput that does not match ... output
shape ... using original output."`).

## How these were captured

A throwaway `CLAUDE_CONFIG_DIR` registered one `PostToolUse` hook matching
`WebFetch|WebSearch|Read|mcp__.*` that piped stdin to a timestamped file in a temp
directory. Four separate `claude -p` runs (haiku, `--max-turns 4`,
`--permission-mode bypassPermissions`) each drove one tool: `Read` on a scratch text file,
`WebFetch` and `WebSearch` against `https://example.com`, and an MCP call against a
trivial local stdio MCP server (`fixturecap`, one tool, fixed text, no credentials, no
network) started via `--mcp-config`. Raw captures lived only in a temp directory and were
never committed; only the shape, with synthetic content substituted in, is checked in
here.

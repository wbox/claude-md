# claude-md

Production-grade hooks and directives for Claude Code.

Claude Code has a set of predictable failure modes that cost you hours if you don't know about them:

- It says "Done." when the code doesn't compile (success = bytes on disk, not a passing build)
- It loses track of your codebase mid-refactor (auto-compaction silently compresses context at ~167K tokens)
- It applies band-aid fixes instead of real ones (system prompt biases toward minimal output)
- It misses code it never read (file reads capped at 2,000 lines, tool results truncated to 2KB previews)
- It misses callers on renames (grep is text matching, not an AST)
- It runs `rm -rf` or exposes `.env` files if you're not paying attention

Anthropic's internal build has fixes for some of these (including a full autonomous verification agent). External users don't get them. This repo patches what can be patched from the outside.

v3 uses hooks (mechanical enforcement that the agent can't bypass) alongside CLAUDE.md (behavioral directives for everything hooks can't check mechanically). Previous versions relied on CLAUDE.md alone, which the agent ignores once context pressure gets high enough.

## What's in here

```
your-project/
  CLAUDE.md                          # planning, code quality, context management, edit safety
  .claude/
    settings.json                    # hook configuration
    hooks/
      post-edit-verify.sh            # lint after every file write
      stop-verify.sh                 # type-check + lint + tests before task completion
      truncation-check.sh            # detect when search results got cut short
      block-destructive.sh           # block rm -rf, DROP TABLE, force push, .env reads
```

**Hooks** run automatically at the system level. The agent can't bypass them, forget them, or deprioritize them under context pressure. If the code doesn't compile, the agent is blocked from completing the task and gets the error output to fix. If a dangerous command is about to run, it's denied before execution.

**CLAUDE.md** handles what hooks can't enforce mechanically: planning discipline (plan before coding, phase work into batches of 5 files), context management (use sub-agents for large tasks, re-read files after long conversations, clean dead code before refactoring), code quality (fix architecture problems, don't apply band-aids), edit safety (re-read before and after every edit, search comprehensively on renames), and self-correction (log mistakes, review past errors at session start).

## What it fixes

| Problem | Why it happens | What fixes it |
|---------|---------------|---------------|
| "Done!" with 40 type errors | Agent checks if write succeeded, not if code compiles | **stop-verify hook** blocks completion until tsc/eslint/tests pass |
| Lint errors pile up across edits | No per-edit checking | **post-edit-verify hook** runs eslint/ruff after every file change |
| Agent runs `rm -rf /` or reads `.env` | No command safety net | **block-destructive hook** denies dangerous commands before execution |
| Grep finds 3 results when there are 47 | Tool results over 50K chars truncated to 2KB preview | **truncation-check hook** warns agent to read full file or narrow scope |
| Hallucinations after ~15 messages | Auto-compaction nukes context at ~167K tokens | **CLAUDE.md** forces phased execution, dead code cleanup, sub-agents |
| Band-aid fixes instead of real solutions | System prompt biases toward minimal intervention | **CLAUDE.md** overrides with "fix what a senior dev would reject" |
| Context decay on large refactors | One agent = one 167K context window | **CLAUDE.md** forces sub-agent swarming (5-8 files per agent) |
| Edits reference code it never read | File reads capped at 2,000 lines | **CLAUDE.md** forces chunked reads with offset/limit |
| Rename misses dynamic imports | Grep is text matching, not an AST | **CLAUDE.md** forces separate searches for every reference type |

## Install

### Prerequisites

You need Claude Code installed and working. If you haven't set it up yet, follow Anthropic's install guide first, then come back here.

You also need `jq` installed (the hooks use it to parse JSON from Claude Code):

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt install jq

# Windows (WSL)
sudo apt install jq

# Check it's working
jq --version
```

### Option A: one-liner install

Run this from inside your project directory:

```bash
curl -sL https://raw.githubusercontent.com/iamfakeguru/claude-md/main/install.sh | bash -s .
```

This downloads everything and puts it in the right place. If you already have a CLAUDE.md, it saves the new one as CLAUDE.md.v3 so you don't lose yours.

### Option B: clone and install

```bash
git clone https://github.com/iamfakeguru/claude-md.git
cd claude-md
./install.sh /path/to/your/project
```

### Option C: manual install

If you want to see exactly what goes where:

```bash
# Create the hooks directory in your project
mkdir -p /path/to/your/project/.claude/hooks

# Copy the hook config
cp .claude/settings.json /path/to/your/project/.claude/settings.json

# Copy the hook scripts
cp .claude/hooks/*.sh /path/to/your/project/.claude/hooks/

# Make them executable
chmod +x /path/to/your/project/.claude/hooks/*.sh

# Copy the agent directives
cp CLAUDE.md /path/to/your/project/CLAUDE.md
```

### Verify it works

Open Claude Code in your project and run any edit task. You should see "Verifying edit..." appear briefly after each file change. If you intentionally break something and ask the agent to finish, the Stop hook should catch it and block completion.

You can also check hooks are loaded:

```bash
# Inside Claude Code, run:
/hooks
```

This shows all active hooks and their matchers.

## What each hook does

### post-edit-verify.sh

Runs after every Write, Edit, or MultiEdit. Checks the modified file with your linter (eslint for JS/TS, ruff for Python). If lint fails, the agent is blocked with the error output and has to fix it before continuing.

Type-checking (tsc, mypy) does NOT run here. On large projects tsc takes 10-30 seconds, and running it on every single edit would make the agent painfully slow. Full type-checking runs once at the end via stop-verify.

### stop-verify.sh

Runs when the agent tries to complete a task. This is the big one. It runs your full verification suite:

- TypeScript: `npx tsc --noEmit` + `npx eslint . --quiet`
- Python: `mypy .` + `ruff check .`
- Rust: `cargo check`
- Tests: `npm test`, `pytest`, or `cargo test` (auto-detected)

If anything fails, the agent is blocked and sent back with the error output. It cannot say "Done!" until everything passes.

If no type-checker, linter, or test runner is found, the hook tells the agent to explicitly state that to you instead of silently claiming success.

The hook has infinite-loop protection: if it blocks the agent and the agent retries after fixing errors, Claude Code sets `stop_hook_active: true` in the hook input, and the hook lets it through on the second attempt.

### truncation-check.sh

Runs after Grep and Bash tool calls. Claude Code truncates tool results over 50,000 characters down to a 2KB preview. The model is told this happened and given a filepath to the full output, but it doesn't always act on that information.

This hook detects truncation and injects a warning into the agent's context telling it to either read the full file at the given path or re-run the search with narrower scope.

It also flags suspiciously low grep result counts as a heads-up (not a block, just a warning).

### block-destructive.sh

Runs before any Bash command executes. Blocks:

- `rm` targeting `/`, `~`, `$HOME`, or `..`
- `DROP TABLE`, `DROP DATABASE`, `TRUNCATE TABLE`, `DELETE FROM` without WHERE
- `git push --force`, `git push -f`, `git reset --hard`
- Reading `.env` files via cat, less, head, tail, source, grep, sed, awk

If blocked, the agent gets a denial message. If the command is something you actually want to run, do it yourself in a separate terminal.

## What CLAUDE.md does

The hooks handle verification. CLAUDE.md handles everything else:

**Planning** - forces the agent to plan before coding, get approval before executing, and break large refactors into phases of 5 files max.

**Code quality** - overrides the default system prompt that biases toward minimal intervention. Tells the agent to fix architectural problems, not apply band-aids.

**Context management** - forces sub-agent usage for tasks over 5 files (each gets its own ~167K token context window). Forces re-reading files after 10+ messages (auto-compaction may have destroyed the agent's memory). Forces chunked reads for files over 500 lines.

**Edit safety** - forces re-reading before and after every edit. Forces comprehensive search on renames (grep, type references, string literals, dynamic imports, barrel files, test mocks).

**Self-correction** - forces the agent to log mistakes to gotchas.md and review past errors at session start.

## Auto-detection

The hooks auto-detect your project type. You don't need to configure anything if you use standard tooling:

| Language | Lint (per-edit) | Type-check (at stop) | Tests (at stop) |
|----------|----------------|---------------------|-----------------|
| TypeScript/JavaScript | eslint (looks for .eslintrc, eslint.config.js/ts/mjs) | tsc --noEmit (looks for tsconfig.json) | npm test (looks for test script in package.json) |
| Python | ruff (looks for ruff binary) | mypy (looks for mypy.ini or [tool.mypy] in pyproject.toml) | pytest (looks for pytest binary) |
| Rust | (at stop only) | cargo check (looks for Cargo.toml) | cargo test |

If your project uses different tooling, edit the hook scripts directly. They're plain bash. Each one is self-contained and commented.

## Customizing

### I don't want lint on every edit

Remove or comment out the first PostToolUse block in `.claude/settings.json`. The Stop hook will still catch everything at the end.

### I want to add prettier / biome / other formatters

Add another PostToolUse hook in `settings.json`:

```json
{
  "matcher": "Write|Edit|MultiEdit",
  "hooks": [
    {
      "type": "command",
      "command": "jq -r '.tool_input.file_path' | xargs npx prettier --write",
      "timeout": 30
    }
  ]
}
```

### I want to block other dangerous commands

Edit `block-destructive.sh` and add more patterns to the grep checks. The structure is the same for each: grep for the pattern, if matched, output a deny JSON and exit.

### I already have a CLAUDE.md

The install script saves the new one as `CLAUDE.md.v3` if yours already exists. You can merge the parts you want manually, or replace yours entirely.

### I'm using Cursor / Windsurf / something else

The hooks are Claude Code specific (they use Claude Code's hook system). The CLAUDE.md content works in any agent that reads a rules file. Copy the relevant directives into `.cursorrules`, `.windsurfrules`, or your agent's equivalent.

## Why hooks instead of CLAUDE.md alone

v1 and v2 of this repo relied entirely on CLAUDE.md directives telling the agent to verify its work. The problem: CLAUDE.md is a suggestion. Under context pressure (long conversations, large codebases, after compaction fires), the agent starts ignoring directives. It's not being disobedient, it's lost the context that contained the directive.

Hooks run at the system level. They fire every time, regardless of context pressure. The agent can't forget them because it doesn't control them.

v3 uses both: hooks for everything that can be mechanically checked (does it compile? does it lint? did results get truncated?), CLAUDE.md for everything that requires judgment (planning discipline, architectural decisions, when to use sub-agents).

## What this doesn't fix

These are Claude Code limitations that can't be patched from the outside:

- **Context compaction** still fires at ~167K tokens (for 200K-context models) and compresses your working memory to ~70K. The CLAUDE.md directives help (keeping phases small, cleaning dead code first) but compaction itself is invisible to hooks.
- **Explore agent defaults to Haiku** for non-Anthropic-employees. You can override it by specifying the model parameter on agent calls, but the default is the cheapest model.
- **The adversarial verification agent** (an autonomous QA pipeline that forces PASS/FAIL/PARTIAL checks) exists internally at Anthropic but is feature-flagged off for external users. The Stop hook approximates its "don't complete until verified" behavior but doesn't replicate the adversarial probing.
- **9 useful commands** (/commit, /autofix-pr, /share, /summary, etc.) and **3 useful skills** (/verify, /skillify, /remember) are stripped from external builds.

## Background

This repo accompanies a two-part analysis of Claude Code's source code:

- [Part 1](https://x.com/iamfakeguru/status/2038965567269249484): original findings on employee-only gates (some later corrected)
- Part 2: fact-check, corrections, and deeper findings including the verification agent and explore model default

Built by [@iamfakeguru](https://x.com/iamfakeguru). I build multi-agent systems at [@OpenServAI](https://x.com/openservai).

## License

MIT. Do whatever you want with it.

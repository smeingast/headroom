@AGENTS.md

## Claude Code specifics

`AGENTS.md` is the shared project guide, read natively by Codex and imported
above for Claude Code; edit the rules there, not here.

- Never use `isolation: "worktree"` for agents or `EnterWorktree` in this repo:
  Claude Code puts those under `.claude/worktrees/`, inside the synced tree.

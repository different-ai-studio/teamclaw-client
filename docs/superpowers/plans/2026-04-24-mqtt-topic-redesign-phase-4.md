# Phase 4 — Internal Rust Renames (agent → runtime)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Rename daemon-internal `agent` symbols → `runtime` to close the naming trap documented in CLAUDE.md glossary ("daemon code calls each Claude Code subprocess an 'agent' but Supabase semantics call that a 'runtime'"). No wire-format changes; purely Rust-side cosmetic.

**Architecture:** Three concentric rings of renames:
1. Module path: `daemon/src/agent/` → `daemon/src/runtime/`
2. Struct types: `AgentManager` → `RuntimeManager`, `AgentHandle` → `RuntimeHandle`
3. Publisher method names: `publish_agent_*` → `publish_runtime_*`, `clear_agent_state` → `clear_runtime_state`

**Conservative scope:** We rename structural identifiers (types, modules, method names). We do NOT rename local variables like `let agent_id = ...`, function parameter names inside bodies, or doc-comment prose. Those accumulate churn without changing any API — future cleanup.

**Tech Stack:** Rust 2021. No proto changes. No iOS changes.

---

## Files

- Move: `daemon/src/agent/*.rs` → `daemon/src/runtime/*.rs` (5 files)
- Modify: `daemon/src/lib.rs` (or `main.rs`) — module declaration `pub mod runtime;` (was `pub mod agent;`)
- Modify: `daemon/src/runtime/mod.rs` — re-export `RuntimeManager` (renamed)
- Modify: `daemon/src/runtime/manager.rs` — struct rename
- Modify: `daemon/src/runtime/handle.rs` — struct rename
- Modify: `daemon/src/mqtt/publisher.rs` — method renames + doc updates
- Modify: Every file that imports `crate::agent::AgentManager` / `crate::agent::AgentHandle` / publisher methods — update imports + call sites
- Modify: `CLAUDE.md` — the glossary section loses the "naming trap" warning (not resolved entirely — there's still `agent_id` local variables — but the structural names align now)

---

### Task 1: Move `daemon/src/agent/` → `daemon/src/runtime/`

**Files:** All of `daemon/src/agent/*.rs` move; callers update imports.

- [ ] **Step 1:** Move the directory.
```bash
cd /Volumes/openbeta/workspace/amux
git mv daemon/src/agent daemon/src/runtime
```

- [ ] **Step 2:** Update the module declaration. Find where `pub mod agent;` is declared:
```bash
/usr/bin/grep -rn "pub mod agent\|mod agent" daemon/src/lib.rs daemon/src/main.rs 2>/dev/null
```
Change `pub mod agent;` → `pub mod runtime;`.

- [ ] **Step 3:** Update every `crate::agent::` import across the daemon:
```bash
/usr/bin/grep -rln "crate::agent::" daemon/src
```
For each file found, edit the import to `crate::runtime::`. Use sed OR hand-edit per file — be careful that `agent` as a local variable/field name elsewhere is NOT touched.

```bash
# Safe in-place sed (macOS BSD sed syntax):
/usr/bin/grep -rl "crate::agent::" daemon/src | while read -r f; do
    sed -i '' 's|crate::agent::|crate::runtime::|g' "$f"
done
```

- [ ] **Step 4:** Update `super::` imports inside the moved files if any use relative paths:
```bash
/usr/bin/grep -n "super::" daemon/src/runtime/*.rs
```
Usually `super::` in module files points at the parent (e.g., `crate`), not `agent` itself, so this is likely a no-op. Verify.

- [ ] **Step 5:** Build with env vars:
```bash
cd /Volumes/openbeta/workspace/amux
export SUPABASE_URL="https://srhaytajyfrniuvnkfpd.supabase.co/rest/v1/"
export SUPABASE_ANON_KEY="sb_publishable_CJavqYCusEBD7cIebhH5tQ_K_I9AXpE"
cd daemon && cargo build 2>&1 | tail -10
cargo test 2>&1 | tail -10
```
Expected: clean build, 98 tests pass.

- [ ] **Step 6:** Commit.
```bash
cd /Volumes/openbeta/workspace/amux
git add -u daemon/src/
# git mv already staged renames; -u also picks up import updates in other files
git commit -m "refactor(daemon): rename agent/ module to runtime/"
```

---

### Task 2: Rename `AgentManager` → `RuntimeManager`

**Files:** `daemon/src/runtime/manager.rs`, `daemon/src/runtime/mod.rs`, every caller.

- [ ] **Step 1:** In `daemon/src/runtime/manager.rs`, rename the struct:
- `pub struct AgentManager` → `pub struct RuntimeManager`
- `impl AgentManager` → `impl RuntimeManager`
- Tests referencing `AgentManager::new(...)` → `RuntimeManager::new(...)`

- [ ] **Step 2:** In `daemon/src/runtime/mod.rs`, update the re-export:
- `pub use manager::AgentManager;` → `pub use manager::RuntimeManager;`

- [ ] **Step 3:** Update every caller. Find sites with grep:
```bash
/usr/bin/grep -rln "AgentManager" daemon/src
```
For each file, replace `AgentManager` → `RuntimeManager`. Common call sites: `daemon/src/daemon/server.rs` (field declaration + `::new` call).

Use sed as a precision tool:
```bash
/usr/bin/grep -rl "AgentManager" daemon/src | while read -r f; do
    sed -i '' 's|AgentManager|RuntimeManager|g' "$f"
done
```

- [ ] **Step 4:** Build + test.
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -10
cargo test 2>&1 | tail -10
```
Expected: clean + 98 pass.

- [ ] **Step 5:** Commit.
```bash
cd /Volumes/openbeta/workspace/amux
git add -u daemon/src/
git commit -m "refactor(daemon): rename AgentManager to RuntimeManager"
```

---

### Task 3: Rename `AgentHandle` → `RuntimeHandle`

**Files:** `daemon/src/runtime/handle.rs` + callers.

- [ ] **Step 1:** In `daemon/src/runtime/handle.rs`, rename:
- `pub struct AgentHandle` → `pub struct RuntimeHandle`
- `impl AgentHandle` → `impl RuntimeHandle`

- [ ] **Step 2:** Update every caller:
```bash
/usr/bin/grep -rln "AgentHandle" daemon/src
```
Replace via sed:
```bash
/usr/bin/grep -rl "AgentHandle" daemon/src | while read -r f; do
    sed -i '' 's|AgentHandle|RuntimeHandle|g' "$f"
done
```

- [ ] **Step 3:** If `mod.rs` re-exports `AgentHandle`, update it to `RuntimeHandle`.

- [ ] **Step 4:** Build + test.
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -10
cargo test 2>&1 | tail -10
```
Expected: clean + 98 pass.

- [ ] **Step 5:** Commit.
```bash
cd /Volumes/openbeta/workspace/amux
git add -u daemon/src/
git commit -m "refactor(daemon): rename AgentHandle to RuntimeHandle"
```

---

### Task 4: Rename publisher methods

**Files:** `daemon/src/mqtt/publisher.rs`, every caller.

- [ ] **Step 1:** In `daemon/src/mqtt/publisher.rs`:
- `publish_agent_state` → `publish_runtime_state`
- `publish_agent_event` → `publish_runtime_event`
- `clear_agent_state` → `clear_runtime_state`
- Update doc comments to remove any "agent" / "legacy" wording leftover.
- The parameter `agent_id: &str` can stay for now (conservative scope) OR be renamed to `runtime_id: &str` for internal consistency. Recommend: rename parameter names too (they only appear in signatures + once in body). Use sed carefully — this is a method-body change.

Actually — let's only rename function NAMES in this task. Keep parameter names alone. This keeps the diff to the .rs files minimal and predictable.

```bash
cd /Volumes/openbeta/workspace/amux
/usr/bin/grep -rl "publish_agent_state\|publish_agent_event\|clear_agent_state" daemon/src | while read -r f; do
    sed -i '' -e 's|publish_agent_state|publish_runtime_state|g' \
              -e 's|publish_agent_event|publish_runtime_event|g' \
              -e 's|clear_agent_state|clear_runtime_state|g' "$f"
done
```

- [ ] **Step 2:** Also rename `publish_agent_state_by_id` in server.rs (it's a helper method on Server, not Publisher, but same naming pattern):
```bash
/usr/bin/grep -rl "publish_agent_state_by_id" daemon/src | while read -r f; do
    sed -i '' 's|publish_agent_state_by_id|publish_runtime_state_by_id|g' "$f"
done
```

- [ ] **Step 3:** Build + test.
```bash
cd /Volumes/openbeta/workspace/amux/daemon && cargo build 2>&1 | tail -10
cargo test 2>&1 | tail -10
```

- [ ] **Step 4:** Commit.
```bash
cd /Volumes/openbeta/workspace/amux
git add -u daemon/src/
git commit -m "refactor(daemon): rename publish_agent_* to publish_runtime_* publisher methods"
```

---

### Task 5: Update CLAUDE.md glossary + final verification

**Files:** `CLAUDE.md`

- [ ] **Step 1:** In `CLAUDE.md`, find the "Concept Glossary" section and "The naming trap" paragraph. Rewrite to reflect the new state:
- The row in the glossary table for "Individual Claude Code subprocess" now has `Daemon code: RuntimeHandle` (was AgentHandle).
- Delete or rewrite "The naming trap" paragraph — the structural trap is resolved. Note that local variable names like `agent_id` may still appear in function bodies as transient traces of the old name; that's not a semantic trap anymore.

- [ ] **Step 2:** Final verification grep. These should be few/none after Phase 4:
```bash
/usr/bin/grep -rn "AgentManager\|AgentHandle\|publish_agent_state\|publish_agent_event\|clear_agent_state\|publish_agent_state_by_id" daemon/src
/usr/bin/grep -rn "crate::agent::\|mod agent;\|pub mod agent;" daemon/src
```
Expected: zero matches for all patterns.

- [ ] **Step 3:** Commit (only if CLAUDE.md was updated).
```bash
git add CLAUDE.md
git commit -m "docs: update glossary — rename AgentManager/Handle → RuntimeManager/Handle"
```

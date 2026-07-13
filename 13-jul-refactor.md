# 13-Jul Refactor — decisions & status

A cascade of architectural decisions taken while building the unified subtree-relocation
primitive. Each item: the decision, why, and its status. Ordered roughly as taken.

Landed commits (before this uncommitted batch):
`d8a457f` labeled-from-birth + strict invariant · `c84ba2e`..`8c8c108` span_rehome/Phase B ·
`7edeb7e` remove Table.reindex (fold into rehome_subtree) · `49473d5` create-in-place (1/2):
Table.create_child + text-split/textContent.

---

## 6. Convention: INDEX-FIRST (index writes before nodes record) — DONE
**Decision:** any op writing BOTH tables writes the index row(s) FIRST, then the nodes record.
**Audit (this session):** 6 WRONG (nodes-first) sites found — `seed_root`, `create_child`
(_table.ex); `write_record` (tree.ex); `init`, `materialize_subtree`, `set_definition`
(dom.ex). `rehome`, `delete_subtree` already correct.
**Status:** ALL FIXED. seed_root/create_child rewritten via NodeData.insert; `init` now uses
`NodeData.insert` for the document node; `set_definition`, `materialize_subtree`,
`write_record` reordered (membership/index write before the nodes record). Only exception:
`create_child`'s span mirror runs after `place_child` carves (extent isn't known until then)
— its membership/span write is still bounded to the one new node. Full suite green.

## 7. `_contents.ex` (range clone/extract) — DEFERRED via temporary seam
**Decision:** the whole module is tid-only; its char-node minting (`new_char_node`) needs the
new arity. Threading index through its ~14-fn recursion IS the create-in-place restructure
planned for LATER (on the unified rehome).
**Temporary seam:** added `Table.create_text_record`/`create_comment_record` (nodes-only,
record via `put`, no index) — the fragment's index rows come from the caller's
`rehome_subtree(fragment)`. `new_char_node` uses these. MARKED temporary; remove when
_contents.ex is restructured create-in-place.
**Status:** seam in place, lib green. Full _contents.ex rewrite = future.

---

## Current build/test status — GREEN, committed checkpoint
- **lib/** + **tests/**: full suite GREEN — 6832 tests + 6 properties (unit + Chromium/Firefox
  oracle). Credo at baseline (2 warnings, 1 refactoring — both pre-existing).
- Test sweep done: `css_table.ex` (placeholder-seeded structs, overwritten by carve_extents),
  `table_test.exs` (top-level setup now gives tid+index; create_* calls + field_tree/el helpers
  threaded), `tree_test.exs` (synthetic Document seeded), `rehome_test.exs` (create_* arity).

## Item 6 — DONE (commit 197fac7). Every both-tables write is index-first.

## Item 1 rollout — rehome caller wiring — IN PROGRESS
- **Detach cases DONE** (commits d4a5e2a, a7386fe): `NodeData.detach(nodes, index, child_id)`
  = the rehome to self-root (keep byte-keys, root→child_id, root's parent→nil). Wired into
  `remove_child_op` and same-server `_adopt_node`. `_remove_subtree`/replace-prepare keep the
  record-only `Table.detach` (they delete/re-insert right after, so no rehome). Removed
  `detach_from_parent`.
- **Move-into-slot cases — NEXT (decision: FULL UNIFY, user).** The ~13 append/insert/graft
  sites (currently `Table.append_child`/`insert_before` + `rehome_subtree`) go onto
  `NodeData.rehome` with an into-slot transform. **To avoid re-deriving graft's key math in
  the lambda:** have `Table.graft` (or a wrapper) RETURN the per-node `%{id => {new_start,
  new_stop}}` mapping; `NodeData.graft_into(nodes, index, parent_id, child_id, position)` then:
  (1) compute dest slot (extent_after_last / extent_before), (2) get the graft mapping,
  (3) `rehome` over the child's CURRENT window `{child.root, child.start, child.stop}` with a
  transform that sets root→parent's tree root, start/stop from the mapping, and the subtree
  ROOT's parent→parent_id (descendants keep their parent). Multi-child (fragment) = multispan
  the gap, graft each. NOTE post-Phase-A the `child.start == nil` fresh-node branch in
  place_child/place_children is DEAD (every node labeled) — only the graft path remains.
  Build incrementally: add graft_into → wire ONE site (append_child_op :else) → green →
  roll out to insert/fragment/subtree-attach/import/clone. Consistency net is the oracle.
- Then `Table.append_child`/`insert_before`/`place_child`/`graft_subtree`/`rehome_subtree`
  become removable (all relocation flows through `NodeData.rehome`).

## Item 7 — `_contents.ex` create-in-place rewrite — FUTURE
Remove the temporary `create_text_record`/`create_comment_record` seam; build the extracted/
cloned tree rooted-in-place on the unified API.

## Related memory
`[[unified-rehome-design]]`, `[[index-before-nodes-convention]]`,
`[[create-in-place-internal-ops]]`.

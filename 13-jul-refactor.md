# 13-Jul Refactor — decisions & status

**STATUS: COMPLETE.** All items done; every subtree relocation in the library flows through
the unified `DOM.NodeData.rehome` (`detach` / `graft_into`). Full suite green (6826 tests + 6
properties, unit + Chromium/Firefox); credo at baseline. Final commit `9a6d05f`.

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

## Item 1 rollout — rehome caller wiring — DONE (except the item-7-gated cluster)
- **Detach** (d4a5e2a, a7386fe): `NodeData.detach(nodes, index, child_id)` = rehome to
  self-root. Wired into `remove_child_op`, same-server `_adopt_node`, replace-child (old node),
  inner/outerHTML removals. `_remove_subtree`/replace-prepare keep record-only `Table.detach`
  (delete/re-insert follows).
- **Move-into-slot** (796ff01, 1df440d, 1838a57): `NodeData.graft_into(nodes, index, parent_id,
  child_ids, position)` — `Table.graft_plan` computes the destination (dest root/parent +
  `%{id => {new_start, new_stop}}` extent map, single source of the key math); graft_into
  `rehome`s each child subtree applying the plan. Wired into append/insert (single + fragment
  multispan), subtree-attach, replace, insert/outer/inner-adjacentHTML, shadow innerHTML.
- **materialize_subtree** now writes both tables (NodeData.insert per node) so a following
  graft_into has span rows to move; adopt/import drop their now-redundant rehome_subtree.
- **clone** (e5a32a4): `Table.clone(nodes, index, …)` writes both tables; `clone_record`
  (record-only) kept as the temporary seam for _contents.ex / tree-builder <template>.
- **Removed** (b05a400): dead `Table.insert_before`, `Table.remove_child` + their obsolete
  Table-level tests.
- **STILL ALIVE, gated on item 7** (used only by _contents.ex / range clone-extract-fragment
  builders / surround / tree-builder): `Table.append_child`, `append_children`,
  `place_child(ren)`, `graft_subtree`, `rehome_subtree` (3 remaining call sites). Removable once
  _contents.ex produces fully-labeled nodes.

## Item 7 — `_contents.ex` create-in-place — DONE (9a6d05f)
DOM.Range.Contents threads `index` and builds fully-labeled nodes (create_text/comment/clone
+ graft_into/detach). Seam (`create_text_record`/`create_comment_record`) + dead legacy
mutators (`append_children`/`insert_children_before`/`place_children`/`rehome_subtree`) removed.
Kept `append_child` + `clone_record` (record-only) for the tree builder's tid-only <template>
clone path only.

## End state
- ONE relocation primitive: `NodeData.rehome(nodes, index, {root,start,stop}, transform)`, with
  `NodeData.detach` (to self-root) and `NodeData.graft_into` (into a parent slot; `Table.graft_plan`
  supplies the key math). `NodeData.insert` is the one both-tables node writer (index-first).
- `root == self` everywhere; enforce_keys makes every node labeled at construction.
- Every `create_*` takes `(nodes, index)`; index-first at every both-tables site.
- Still record-only (tree-builder parse path, by design): `Table.append_child`, `clone_record`,
  `place_child`/`graft_subtree` (via append_child), `span_index_all` (bulk parse mirror).

## Related memory
`[[unified-rehome-design]]`, `[[index-before-nodes-convention]]`,
`[[create-in-place-internal-ops]]`.

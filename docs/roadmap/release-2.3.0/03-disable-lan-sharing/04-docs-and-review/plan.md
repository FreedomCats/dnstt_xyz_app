---
kind: task
status: done
depends: [03-verify-local-only]
---

# Close review item 3 and document the local-only proxy

## Task

Record the result: `docs/CODE_REVIEW.md` item 3 is closed by removing the share
mode, `CLAUDE.md` says the proxy modes listen on loopback only, and
`docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` section 5.1 describes the implemented
removal instead of pending work. Documentation only; no code, test or workflow
change.

Item 3 keeps the original problem statement and gets a `**Resolved.**`
paragraph in the style of items 6 and 3.3, with the reason: the mode was
unreachable from the UI, so the `0.0.0.0` branches and `EXTRA_SHARE_PROXY`
handling in `DnsttProxyService.kt`, `SlipstreamProxyService.kt` and
`SshTunnelClient.kt`, the channel methods `setProxySharing`,
`isProxySharingEnabled`, `connectProxyShared` and `getLocalIpAddresses`, and the
Go API `setShareProxy` / `IsShareProxyEnabled` are removed; every proxy listener
binds `127.0.0.1`; a password-protected version can return as its own stage. The
"Suggested order of work" item 2 must stop asking for a SOCKS password.

`CLAUDE.md` line 421 loses the `0.0.0.0` sharing mention and the relay is
described as `127.0.0.1:<port>` only; the proxy-mode section and the mode list
say the same. Architecture section 5.1 is rewritten in present tense, keeping
the section number and the surrounding structure. `docs/ROADMAP_WORKFLOW.md:118`
records the decision itself and stays unchanged; historical `docs/STAGE*.md`
reports are not rewritten.

## Done when

- `CODE_REVIEW.md` item 3 has a `**Resolved.**` paragraph with the reason, and
  the suggested work order no longer asks to add a password.
- `CLAUDE.md` describes the relay and every proxy mode as loopback-only.
- Architecture section 5.1 describes the implemented removal and the possible
  follow-up, not work to do.
- `grep -RIni "share proxy\|proxy sharing\|0\.0\.0\.0:<port>\|shareproxy"
  CLAUDE.md docs/ README.md` leaves only `docs/ROADMAP_WORKFLOW.md:118`, the
  original problem statement plus the resolved paragraph of `CODE_REVIEW.md`
  item 3, and this stage's node files.
- Only documentation files change; `git diff --check` passes.

## Risks and what is needed from the user

- `docs/ROADMAP_WORKFLOW.md:118` records the decision itself; it stays as
  written and is not a claim that the feature still exists.
- Do not rewrite historical stage reports (`docs/STAGE*.md`): they describe the
  state at the time.
- No user input is needed; the decision to remove the mode was taken already.

## Outcome

- `docs/CODE_REVIEW.md` item 3 now has a `**Resolved.**` paragraph: the share
  mode was unreachable from the UI and was removed instead of given a password;
  the removed Kotlin branches and channel methods and the removed Go API are
  named, and every proxy listener binds `127.0.0.1`. The suggested work order
  now says to remove the mode, not to add a password.
- `CLAUDE.md` describes the relay and both Android proxy modes as loopback-only
  and points to review item 3.
- Architecture section 5.1 is present tense: the implemented removal, the
  listener-inventory result, and the possible password-protected follow-up as a
  separate stage. The section-5 preamble lists 5.1, 5.3 and 5.4 as implemented.
- No code, test, workflow or generated file changed. The share-term grep leaves
  the original problem statement plus this resolved paragraph in
  `CODE_REVIEW.md`, `docs/ROADMAP_WORKFLOW.md` (the decision record), the root
  stage description, the historical `docs/STAGE1_GO_LIBRARY_CI.md`, architecture
  5.1's description of what was removed, and this stage's node files. All are
  accurate references to the removed API, not stale claims; the literal
  allowlist in `## Done when` did not anticipate the historical report and the
  architecture resolution text.

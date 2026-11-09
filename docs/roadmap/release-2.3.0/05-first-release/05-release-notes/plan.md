---
kind: task
status: todo
depends: [02-run-release-workflow, 03-verify-artifacts]
---

# Finalize the release page and its notes

## Task

`release.yml` publishes the release with a fixed body stored in the workflow
(`release.yml:526-561`): it is the upstream template, it does not mention the
DoH/DoT transports, the tun2socks VPN path, the removed share mode or the SSH
host key verification, and it does not warn that this app uses the same
application ID as the upstream app. The stage requires the signing certificate
SHA-256 in the notes; the template already inserts it from
`build-android.outputs.cert-sha256`, so the check is that the line is present and
carries the verified value.

Editing a published release is an outward action: prepare the text, show it to
the user and apply it only with the explicit go-ahead.

## Steps

1. Read the published release (`gh release view v2.3.0-beta` or the web page)
   and check the frame: the tag and the release title, the target commit, the
   pre-release flag (the workflow marks a tag containing `beta` as a
   pre-release, `release.yml:563`), and the five assets with the names the README
   table promises.
2. Check the certificate line of the body: the SHA-256 there must equal the
   digest verified in [03-verify-artifacts](../03-verify-artifacts/plan.md).
   A different value is a defect, not a typo to edit.
3. Draft the body. It must stay within `AGENTS.md`: no names, no work dates, no
   environment, no servers, resolvers or addresses. Cover:
   - what 2.3.0 adds, taken from `docs/DOH_DOT_TUN2SOCKS_ARCHITECTURE.md` and
     the stage reports: DoH and DoT for DNSTT and Slipstream, the tun2socks VPN
     mode, Slipstream built from the vendored source for the three Android
     ABIs, SSH host key verification, SOCKS5 username/password authentication
     for the upstream proxy, and the loopback-only proxy after the share mode
     was removed;
   - Android install: the app has the same application ID as the upstream app;
     an installed build signed with another key must be exported and uninstalled
     before the release APK installs, an install of this project's key updates
     in place;
   - macOS: the app is ad-hoc signed, not signed with a Developer ID, so the
     first launch needs Right-click → Open (or the quarantine attribute
     removed);
   - what is not in the release: the Windows and Linux jobs are disabled, so
     only Android and macOS are here;
   - how to verify the APK: the certificate SHA-256 above and the
     `apksigner verify --print-certs` command.
   Keep the existing download list and the desktop usage steps from the
   template; keep it short. Store the draft outside the repository (session
   temporary directory or `docs/local/`), not in a tracked file.
4. Show the draft to the user. On the go-ahead apply it with `gh release edit
   v2.3.0-beta --notes-file <file>` or the web form. Do not change the tag, the
   assets or the pre-release flag in the same step; each needs its own
   go-ahead.
5. Re-read the page and confirm the digest line, the five asset names, the flag
   and the body. Record the result in the journal.

## Done when

- The release page shows tag `v2.3.0-beta`, the pre-release flag, the five
  assets under the README names, and the certificate SHA-256 equal to the
  verified digest.
- The body states what 2.3.0 adds, the Android export-and-uninstall caveat, the
  macOS ad-hoc signing caveat and the absent Windows and Linux builds.
- The text was shown to the user and applied with the go-ahead; the page was
  re-read after the edit.

## Risks and what is needed from the user

- The release page is public and the edit is an outward action; the user reads
  the draft first. Nothing in it may identify the developer (`AGENTS.md`,
  "Personal data").
- The workflow template stays stale for later releases unless someone changes
  it; this task edits the published page only. Turning the finished body into
  the template is a separate node if the user wants it.
- The certificate digest is copied from
  [03](../03-verify-artifacts/plan.md), never retyped from memory; a wrong
  digest in the notes would make the verification instructions wrong for every
  user.
- Replacing an asset or deleting the release is not part of this task: both are
  outward actions and change what users may already have downloaded.

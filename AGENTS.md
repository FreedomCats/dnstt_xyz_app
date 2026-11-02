# Project rules for agents

## Language

Code comments, commit messages, Claude memory and documentation (`README.md`,
`CLAUDE.md`, `docs/`, Fastlane metadata) are written in English. Chatting with
the user may be in any language.

## Personal data — never in the repository

**This is a matter of the developer's safety, not tidiness.** The app is a
censorship circumvention tool. If the developer is identified, their life,
health and freedom are at risk. So nothing that can identify them may get into
the repository: real name, email, IP addresses, profile and account names, the
organization they work for, details of the work environment and OS, user name —
or any other detail that makes them easy to find. When in doubt, leave it out.

The repository is public. Documentation (`README.md`, `CLAUDE.md`, `docs/`,
examples), code, tests, comments, Fastlane metadata and commit messages **must
not** contain:

- the user's real name, their emails (personal and work), the name of their
  personal GitHub account and other accounts, their employer;
- the developer's environment: the distribution and machine (and its host name)
  the work is done on, user name, groups, home directories (`/home/…`,
  `/Users/…`, `C:\Users\…`), work networks;
- test devices: phone model, serial number and `adb` ID, firmware version,
  device name on the network;
- dates and times of work: when something was done, tested, checked;
- the user's external IP addresses: home address and VPS address;
- real tunnel servers: tunnel domain and NS records, IPs and ports of DNSTT,
  Slipstream and SSH servers, Noise public keys of real servers;
- DNS resolvers used in live testing, unless they are well-known public
  resolvers (`8.8.8.8`, `1.1.1.1`, etc.): ISP, home router and corporate
  addresses;
- home network addresses (ULA prefix, local machine addresses) and corporate
  network addresses (corporate VPN server, corporate DNS, search domains);
- real config import URLs, exported config files and the user's DNS server
  lists;
- unredacted logs of live runs (`adb logcat`, `slipstream-client` output, Go
  logs): they contain domains, destination addresses and resolvers;
- the user's config and profile names;
- passwords, keys and any secrets: SSH and SOCKS5 usernames and passwords, SSH
  private keys, signing keystores (`*.jks`, `*.keystore`),
  `android/key.properties` and their passwords.

Use words or placeholders instead: "VPS address", "home address", "tunnel
server", `<domain>`, `<key>`, `<config>`, `10.x`, `192.168.1.x`, `fd…`, user
`user`. In tests and examples use documentation values: domains `example.com`,
`t.example.com` (RFC 2606), addresses `192.0.2.0/24`, `198.51.100.0/24`,
`203.0.113.0/24`, `2001:db8::/32`, obviously made-up keys.

These values may be shown to the user in chat. Not in repository files.

## Builds: what leaks into binaries and signatures

Prebuilt files that live in the repository or ship in releases (`dnstt.aar`,
`libslipstream_client.so`, `libdnstt.*`, `slipstream-client`, APK, DMG) must not
contain personal data either:

- Build Go with `-trimpath` (and `-ldflags="-s -w"`) from a temporary
  directory, as described in `CLAUDE.md`; build Rust with
  `--remap-path-prefix` or in CI.
- Before committing a binary, check that it contains no paths or names from the
  machine: `scripts/check_binary_paths.sh <file>` (it also unpacks `.aar` and
  `.apk` and checks the native libraries inside). The expected result is
  "ok" for every file.
- A release APK contains the absolute path of the project directory: the Dart
  AOT snapshot `libapp.so` keeps the URI of the generated plugin registrant
  (`file://<project>/.dart_tool/…`). Build release APKs only in CI, never on
  the developer's machine.
- Create the Android signing key without a real name: only neutral values in
  `keytool -dname` (`CN=FreedomCats` or similar). The signing certificate is
  published with every APK.
- On macOS sign ad-hoc only (`codesign --sign -`): a Developer ID certificate
  contains the owner's name. Strip extended attributes (`xattr -c`).
- Remove build metadata from APKs (the "Cleaning APKs" section in `CLAUDE.md`).
- Prefer building releases in CI rather than on the developer's machine.

## Documents in `docs/`: what is published and what is not

Everything directly in `docs/` is in the repository. All rules above apply to
these documents: no work dates, no time of day ("at night", "late"), no
environment, machine or device, no names or paths — only the substance. Results
of live tests may be written down — without environment, link speeds, servers,
resolvers and addresses; the day-by-day course of work goes only into logs.

Two subdirectories are outside git (`.gitignore`):

- `docs/local/` — stage plans and logs `plan-*.md` (they inevitably contain
  environment and dates), the roadmap journal and other working notes (the
  resume point for new sessions) and copies of documents before cleanup;
- `docs/runs/` — scripts, configs and logs of live runs.

Check a new document against this file before `git add`; put a draft containing
environment details into `docs/local/`.

## Roadmap: where the plan and the state live

Work is planned as a tree of nodes under `docs/roadmap/` and carried out node by
node by the `lead` agent. `docs/ROADMAP_WORKFLOW.md` describes the scheme; these
are the rules of this repository.

- **The map is `docs/roadmap/<slug>/plan.md`**, not the default `doc/roadmap/`:
  the project keeps all its documents in `docs/`, and this file governs what may
  be published there. `docs/roadmap/README.md` lists the maps.
- **The map is published**, so all the rules above apply to it: English, no
  dates, no environment, no servers, resolvers, addresses, device data.
- **The journal is not published.** It is `docs/local/roadmap/<slug>/journal.md`
  and holds the resume point, the decisions with their reasons and the rejected
  options. The map has a one-line `journal.md` pointing there. The journal is
  written after every node, unattended, which is exactly how environment details
  leak into a document — hence the separate place.
- **No dates in the journal.** An entry names the node and the commit; a date
  adds nothing a reader cannot get from `git log`.
- **Stage plans are nodes of the map**, not `docs/local/plan-*.md` files. A
  finished stage is recorded as a line in the root `plan.md` with a link to its
  `docs/STAGE*.md` report, not as a map node: the `lead` creates a directory for
  every stage listed and would plan the work again.
- **The map's language is `lang: en` in its root**, and the headings follow
  it: `## Done when`, `## Stages`, `## Steps`, `## Outcome`, and the stage
  fields `Goal`, `What to do, what is touched`, `Depends on`, `Risks and what
  is needed from the user`. The `lead` and `planner` rules name these sections
  in Russian and know both sets; nothing has to be translated back for them.
- **A task is detailed when it has `detailed: true`**, not when it has a steps
  section: the `planner` sets the field, and `lead` decides from the field.
- **Commits of map files** follow the rules below, like every other commit: no
  Jira number is used in this repository's history.

## Third-party code under an incompatible license

The project's own code and `go_src/` (dnstt) are distributed under CC0 1.0.
Code under a license that does not allow distributing it that way (GPL, AGPL,
PolyForm Noncommercial and similar) is not opened or copied by the implementer —
whoever writes the code. Among neighbouring projects this includes, in
particular, the qWDTT and CSQTT Android clients and the third-party
CSQTT-Windows client. Before reading another project to implement a similar
feature, check its license.

The `vendor/slipstream-rust` submodule is vendored and may be read; when moving
code from it into the project, follow its license.

If you need to know what code under an incompatible license does, another
participant reads it — the coordinator or a separate agent that then does not
write the code itself. They pass the implementer a description of the behaviour
in their own words: which requests and fields, order of steps, timings,
conditions, observable results. The description does not repeat the structure
of the code, function and variable names, or line order; code fragments, even
paraphrased, are not passed on. Protocols, formats and behaviour are facts and
are implemented from scratch.

Best of all are facts from the primary source: a live recording of the
service's behaviour, analysis of packets and responses. Record where the
description came from (the other project, without paths from the machine) in
the stage log (`docs/local/`).

## Commits

Author and committer are only `FreedomCats <noreply@freedomcats.invalid>` (set
in the repository's `.git/config`). The date is today's, but without the time:
midnight UTC. Time of day and time zone do not get into history:

    d=$(date -u +%F)T00:00:00Z
    GIT_AUTHOR_DATE=$d GIT_COMMITTER_DATE=$d git commit …

The `.invalid` domain is reserved (RFC 2606): nobody has such an email, and
GitHub will not attribute the commits to someone else's account.

The same applies to `--amend`, `rebase`, `cherry-pick` and merge commits: git
sets the committer date to the current time. Do not put session links or other
account-bound service links into commit messages.

Release tags (`v*`) are lightweight only: `git tag v2.3.0`, without `-a`, `-s`
or `-m`. An annotated tag stores the name, email and date of whoever created it.

Commits made through the GitHub web interface (the PR merge button, editing a
file in the browser) are signed by the account that clicked the button. Merge
locally, following the rules above, or make sure the account is not a personal
one.

**Before every commit** check `git diff --cached` for everything listed above:
server domains and keys, addresses and resolvers from live runs, values from app
configs and settings, usernames and passwords, paths and names from the
developer's machine, device data, dates. After the commit run
`git log -1 --format='%an <%ae> %ad | %cn <%ce> %cd' --date=iso-strict`. The
forbidden values themselves are not written into this file or into check
scripts.

If something like this does get into history, tell the user immediately.
Cleaning history (`git filter-repo`, `--amend` with force-push) rewrites commit
hashes and is done only with the user's consent.

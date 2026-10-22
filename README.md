# Comet

Comet is a public, native Mac app that makes running GitHub Actions on your own Mac easy to set up and quiet to manage.

It’s aimed at developers with a handful of trusted repositories: connect GitHub, add a runner, and see **whether it’s ready, what it’s doing, and whether anything needs attention**. The menu bar handles everyday control; the main window provides activity, logs, and configuration.

The core advantage is simpler setup and a polished Mac experience. Current-user, dedicated-user, and macOS VM execution support that goal without making users manage the underlying machinery themselves.

## Download and update

Download [Comet.dmg from the latest GitHub Release](https://github.com/captenmasin/comet/releases/latest/download/Comet.dmg). The initial DMG is for Apple Silicon and macOS 15+. Open it and drag Comet into Applications. Release apps and disk images are Developer ID signed, notarized by Apple, and carry stapled tickets for offline verification.

Comet uses [Sparkle](https://sparkle-project.org/) to check for and download updates automatically from GitHub Releases. **Check for Updates…** in the Comet menu or menu-bar overflow checks in the app. Settings lets you disable automatic checks or downloads. Updates, the update feed, and the app are signed; the DMG and app are notarized. Downloaded background updates install on normal Quit, after Comet stops its runners. If you choose to install an update while runners or setup are active, installation waits until all runners are stopped and setup finishes. Configuration, Keychain credentials, runner workspaces and VM disks stay in their existing locations.

Version 0.1.1 and earlier need one manual download and installation to gain the updater. Development/debug builds do not start it. The feed is hosted at [the latest release's appcast.xml](https://github.com/captenmasin/comet/releases/latest/download/appcast.xml); each feed entry points to its exact release's DMG.

## Run locally

Requires Xcode 27 or later to build and macOS 15 or later to run. Automatic macOS VM execution requires Apple Silicon and macOS 27 or later. This development build has been compiled on Apple Silicon; Intel and macOS 15 runtime support have not been validated.

```sh
./scripts/run.sh
```

This builds an ad-hoc signed app at `.build/Comet.app` and opens it. You can also open `Package.swift` in Xcode. SwiftPM resolves Sparkle 2.10.0 using the checked-in `Package.resolved`; there is no GitHub CLI requirement for app users.

The packaging script passes the selected macOS SDK explicitly to the linker and checks the executable's SDK metadata. Quit Comet before packaging; the script refuses to overwrite a running app, which can disrupt macOS local network permissions. Use it for appearance checks: a plain SwiftPM build on the current toolchain can record SDK 15 despite compiling against a newer SDK. The macOS 15 deployment target stays separate from the build SDK. Native sidebar, popover, sheets and controls follow the system appearance; the main Start/Stop button uses Liquid Glass on macOS 26+ and a bordered control on macOS 15. The compact layout uses an adaptive violet accent in light and dark appearances.

The app keeps its original bundle identifier (`dev.runnerbar.app`), Keychain service (`dev.runnerbar.github`), and `RunnerBar` data directory so the rename preserves existing setup. Quit the old Runner app normally before switching to Comet: helper recovery deliberately checks the executable path, which changes with the app name. Do not run both versions together.

## App diagnostics

Comet records app lifecycle events, menu bar insertion/removal, Dock policy changes, runner state/error changes and update installation/relaunch events in `~/Library/Logs/Comet/app.log`. Choose **Show App Logs…** in the app menu or menu-bar overflow to open that folder. Logs include timestamps, process IDs and the launching app's version/path, plus a heartbeat every minute while the main thread is responsive. `app.previous.log` keeps the previous 1 MiB; both logs are local and private to your account. Known token patterns are redacted, but review logs before sharing because errors can include local paths and repository details.

Events are also available in Console under subsystem `dev.runnerbar.app`, category `app`, with details marked private. Use the private log files for full diagnostics, or stream system events with:

```sh
/usr/bin/log stream --style compact --predicate 'subsystem == "dev.runnerbar.app" AND category == "app"'
```

An orderly exit records `will terminate`; a process disappearing without it suggests an abrupt exit. macOS crash reports remain in `~/Library/Logs/DiagnosticReports/` (including `Retired/`); freeze/performance reports can also be in `/Library/Logs/DiagnosticReports/`. Match timestamps and process IDs: runner helpers also use the name Comet. Reopening Comet restores a removed menu bar item; **Show Menu Bar Icon** is also available in the app menu. An inserted item can still be hidden by macOS when the menu bar has insufficient room.

## App artwork

The app icon lives in `Artwork/Comet.icon`, editable with [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer). The packaging script compiles its layers and appearance settings into `Assets.car`, includes a `Comet.icns` fallback for older macOS versions, and merges the generated icon metadata into the app's `Info.plist`:

```sh
./scripts/build-app.sh
```

The existing monochrome template glyph is separate: `swift scripts/generate-icons.swift` regenerates its checked-in 18/36 pixel PNGs in the Swift package resource bundle, checking dimensions and transparency. The menu bar uses state-specific SF Symbols. Swift target names remain internal implementation details.

The DMG uses the checked-in `Artwork/Installer/background.png` and `FinderLayout` metadata for a compact drag-to-install window. Packaging copies these assets without running Finder, so it works on the headless release runner. Run `swift scripts/generate-installer-background.swift` to redraw the Retina background. To change the window or icon positions, regenerate the layout with `python3 scripts/generate-installer-layout.py` in a temporary virtual environment containing `ds-store==1.3.3`. Keep the 660 × 360 point background, icon positions, volume name (`Comet`), and hidden `.background/background.png` path in sync. The layout uses a portable Carbon alias with no build machine paths or file IDs.

## Connect GitHub with a token

1. In Comet, choose **Add Runner** and acknowledge that you trust the workflows.
2. Choose **Create a token on GitHub**. This opens GitHub's fine-grained token form with Administration read/write and Actions read preselected. Review the permissions and choose a suitable expiry (the link suggests 30 days).
3. Select the **Resource owner**, choose **Only select repositories**, and select the trusted repositories you administer. A fine-grained token covers one resource owner. Organization policies may require approval or prohibit tokens; outside-collaborator access also has GitHub limitations.
4. Generate the token on GitHub, paste it into Comet's password field, and choose **Connect GitHub**. Comet validates the account before saving the token in macOS Keychain. Do not paste tokens into chat or source files.
5. Choose a repository, give the runner a unique name, and choose **Add and Start Runner**. Comet downloads the official release for your Mac, verifies its SHA-256 digest against GitHub's release metadata, registers it, and waits for GitHub to confirm it online.
6. In **Configuration → Workflow Snippet**, copy the generated `runs-on` label into a workflow you manage. Comet does not edit workflows for you.

The account must have repository admin access. Token permissions cannot grant privileges your account lacks. Metadata read access is included automatically. Classic tokens can authenticate too, but the setup guide recommends fine-grained tokens to restrict repository access.

When the token expires, is revoked, or needs a different set of repositories, create a replacement and paste it in **Settings → Replace Token**. Failed validation preserves the previous token. One token is stored for this initial version. Changing it does not revoke the old token on GitHub. To disconnect fully, stop/remove runners, revoke the token on GitHub, and delete the `dev.runnerbar.github` item in Keychain Access.

The first development launch may prompt for Keychain access; rebuilding an ad-hoc signed app may prompt again. Tokens are not placed in UserDefaults, configuration exports, runner command arguments, or workflow environments. Registration uses a separate short-lived runner token.

References: [GitHub token setup and limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens), [repository runner API and permissions](https://docs.github.com/en/rest/actions/self-hosted-runners).

## Behavior and storage

Comet shows its main window on the first launch. Later launches open in the menu bar without a Dock icon or main window. Choose **Open Window** from the menu bar for activity, logs and configuration; Comet appears in the Dock while an app window is open. Closing the last app window hides the Dock icon and keeps Comet and its runners running in the menu bar. On first launch, Comet asks whether to **Launch at Login**; declining leaves it off. Change this later in Settings. If macOS requires approval, Settings links to **System Settings → General → Login Items**. Login launch opens only the menu bar; individual runners still follow their **Run automatically** preferences.

Current-user runner installations, checkouts, downloaded actions and tool caches live under `~/.comet/runners/<UUID>`. This keeps Comet’s default execution paths out of `Application Support`, whose space breaks some setup actions. No workflow edits or per-project path settings are needed. On upgrade, Comet moves the previous runner tree while preserving registrations, credentials and workspace files. It refuses migration while a host runner is active or if both locations already contain data. A compatibility link at the old location keeps cached tools with embedded absolute paths usable; new processes use the physical new location.

Choose **Execution → Dedicated user (sudo)** in setup or Configuration to run macOS jobs as the hidden `_comet` account while Comet stays in your account. No OS image or VM is needed. The first start, or **Set Up Dedicated User…**, requests administrator approval to create the account and install validated sudo rules. Password login is disabled. The account has its own home, temporary files, caches and signing keychains, with a separate workspace for each runner under `/Users/_comet/.comet/runners/<UUID>`.

Comet also downloads a stable Homebrew release into `/opt/comet-hb` on Apple Silicon or `/opt/comet` on Intel, owned only by `_comet`. The prefix matches the standard prefix’s byte length to preserve serialized paths in packages and fits Homebrew’s [binary relocation requirements](https://docs.brew.sh/Support-Tiers#custom-prefixes). The dedicated PATH contains this installation, the account’s `~/.local/bin`, and system tools; it excludes `/opt/homebrew` and `/usr/local/bin`. Existing runner registrations refresh their cached PATH on the next start. Your host Homebrew installation is neither adopted nor granted additional write access. The root-owned `/var/db/comet-homebrew` record prevents adoption of an unrelated existing prefix. A shallow copy of the package catalog avoids a large history download when setup actions request local formulae. No project packages are selected by Comet: workflows install their own tools with Homebrew or other setup actions. Source builds may still be needed when a package has no compatible bottle. Tools remain installed between jobs and are shared by dedicated runners on this Mac.

**Dedicated-user execution grants workflows unrestricted root access through sudo.** It separates everyday files and configuration but does not protect the host or your personal files from those workflows. Use trusted repositories only. All dedicated runners share this account and its tools; concurrent tool setup or keychain changes may conflict. This mode does not create a separate logged-in desktop. Electron tests and release signing still require a real workflow check under the new account.

Comet reads status and logs through its helper as `_comet`, and stops verified runner process groups as root so elevated workflow commands can be signalled. Failed status checks prevent duplicate starts, removal and execution changes. Setup refuses to adopt an existing unmanaged `_comet` account or home. Switching execution preserves the workflow label and old files. Removing a runner preserves its workspace, the service account and its sudo rules; to revoke the dedicated account’s permissions, stop all its runners first, then remove `/private/etc/sudoers.d/comet` with administrator privileges. The account ownership record lives at `/var/db/comet-user`.

Choose **Execution → macOS VM** in setup or Configuration to run jobs in a dedicated VM while Comet stays on the host. Comet uses Apple’s Virtualization framework directly; no separate VM app, CLI, or container runtime is required. This option needs Apple Silicon and macOS 27+ for unattended guest setup; local execution keeps the macOS 15 minimum.

Select **Download macOS…** to download the installer from Apple explicitly. Its approximate 27 GB size is shown before downloading, progress is displayed during the transfer, and **Cancel Download** stops it. Merely choosing VM execution or starting an unprepared runner does not download anything. Quit cancels an active download. The completed installer is cached once at `~/Library/Application Support/RunnerBar/macOS.ipsw` and reused for every VM. Allow at least 80 GB free for the installer and guest. Once downloaded, **Set Up VM…** installs macOS on a 64 GB sparse disk with four CPUs and at least 4 GB RAM, provisions the `comet` account, and starts the runner. Package with `scripts/build-app.sh` so Comet has the virtualization entitlement.

Before starting a VM runner, Comet checks Command Line Tools and Homebrew and installs them if missing, including in existing VMs. It uses [Homebrew’s official noninteractive installer](https://github.com/Homebrew/install/blob/main/install.sh), which also installs Command Line Tools through Apple Software Update. A temporary sudo helper uses the VM password sent over SSH input; the password is kept out of command arguments and logs. Comet verifies both tools before continuing. Any required Apple licence acceptance is reported for the user to complete.

VM setup also validates and installs a passwordless sudo rule for the guest’s `comet` account so setup actions can install tools without prompts. **Workflows can become root inside their VM.** This does not change host sudo permissions. An existing unrelated rule at `/private/etc/sudoers.d/comet` is preserved and blocks setup; Comet does not replace it.

Comet prepares a shallow Homebrew package catalog so setup actions can use local formulae without downloading the catalog’s full Git history. Existing valid catalogs are reused; conflicting files are preserved and reported.

Workflow setup actions can install PHP, Composer, Node, Xcode, or other required tools. **Copy VM Password** supplies the guest password when an installer requests it. VM passwords are kept separately in Keychain. Comet connects over SSH with a per-VM known-hosts file, copies in the verified official runner and its complete app bundle as the helper (preserving its code signature and embedded frameworks), and keeps the GitHub management token on the host. No host folders, clipboard, or agent sockets are shared. NAT networking still permits access to reachable network services.

The guest runner and workspace live at `/Users/comet/.comet/runner`, avoiding spaces that break some setup actions. On the next start, Comet moves older guest installations while preserving their registration, credentials, checkouts and caches. A compatibility link keeps cached absolute paths usable; new jobs use the new physical path.

Starting a VM runner enables automatic queue watching while Comet is open. Comet checks all enabled VM runners’ repositories every 30 seconds and wakes a compatible VM for queued work. The guest listener accepts one job and exits naturally; after roughly 60 idle seconds the VM shuts down, retaining its tools and workspace. “Sleeping” means queue watching is still enabled. Manual Stop disables watching, including across app relaunches; normal Quit preserves that preference. Queued jobs wait while Comet is closed. A queue or connection error keeps a running VM on. If a job is cancelled after the listener starts waiting for it, Comet conservatively leaves that listener and VM running rather than risk interrupting a newly assigned job.

Stop a runner before changing execution. Changing execution deregisters its old stopped registration, preserves its files, and creates a fresh environment with the same workflow label. Removal preserves VM disks too. Stop and normal Quit stop the guest runner and request macOS shutdown; closing the VM window leaves it running. Force-quitting Comet powers off its VMs and can interrupt guest disk writes. VMs retain their workspace between jobs; they are not reset automatically. Disks live under each runner’s `vm` folder. Installer images and disks are not pruned automatically.

- Enable **Run automatically** in setup or a runner’s Configuration to start it whenever Comet opens and restores its GitHub credentials. It defaults to off for new and existing runners. Manual Stop leaves this preference enabled for the next app launch. VM runners keep their existing queue-watching behavior: watched VMs resume sleeping until work arrives; other opted-in VMs are prepared and begin watching. Changing execution preserves this preference.
- One shared state drives the menu bar and the main window. Activity shows actual GitHub jobs, Logs shows the local runner output, and Configuration includes the targeting snippet and removal.
- The comet’s head spins while a runner is working. A red dot marks runner/app errors or a runner’s latest known failed job. Successful jobs show a green dot for two minutes after completion; red takes priority. Sleeping status labels are orange.
- Configuration and the shared macOS installer live under `~/Library/Application Support/RunnerBar/`; runner data lives under `~/.comet/runners/`. Configuration is written atomically with restricted permissions and remains readable after first unlock, including while the desktop is locked; each runner has a UUID-owned directory. Existing Mac Runner installations are untouched.
- A helper mode in the app executable owns a per-runner file lock. Relaunch checks the helper's PID, process start time, executable, launch arguments, and process group before signalling it. Duplicate starts are refused. Normal Quit stops runners; closing the window leaves them active. After a force-quit, reopen the same app to reconnect to surviving helpers.
- Current-user and dedicated-user Start show Ready after the local helper exists and GitHub reports the registration online. VM Start prepares the guest, then watches for queued jobs before starting its listener. Connection errors do not erase historical state. Status polling backs off after failures.
- Stop asks for confirmation because job assignment can race with status polling. It sends an interrupt to the managed process group, escalating after 15 seconds if necessary. Workflows that deliberately detach processes need separate cleanup. Current-user jobs run as you; dedicated-user jobs can become root through sudo.
- Right-click a runner in the sidebar to start/stop it, open Configuration, reveal its workspace, or remove it. Backspace on a selected, stopped runner also asks to remove it. Remove requires a stopped runner and deregisters it on GitHub first. Local files and the workspace are always preserved in this initial version. If the registration was already deleted remotely, Comet first verifies repository access before forgetting it locally. Do not manually delete a folder while its runner is active.
- The local displayed/exportable log is bounded to 512 KiB, with common management-token patterns redacted. Review exports before sharing: diagnostics may contain repository paths and workflow output. Full job logs are on GitHub. The official runner also writes `_diag` files, configured for 8 MiB log pages and seven-day retention using its native log settings. Workspaces and tool caches are not automatically pruned.
- Recent jobs cover this runner's jobs from the repository's 10 latest workflow runs. This is a bounded first version, not a complete history archive. Comet status and selected-runner activity poll independently, waiting five seconds after each scan, with separate backoff after failures. Activity fetches up to three runs' job lists concurrently; network time adds to the refresh interval. Duplicate refreshes share a scan. Unchanged completed jobs are cached; active jobs and reruns are fetched again. GitHub rate-limit cooldowns also apply to manual refresh.
- Activity shows GitHub-reported steps for the running job, with outcomes and elapsed durations, using the existing jobs response. Missing or invalid times show `—`; completed work never keeps counting. Failed activity refreshes label retained progress as last known and stop its timers. Progress updates depend on polling; View on GitHub opens the complete job output.
- If setup fails, its configuration and files remain visible for retry or removal. No automatic cleanup deletes a workspace. Registration/configuration can continue briefly if the app is force-quit during setup; inspect the repository's runner settings and local folder before retrying.

## Optional MCP diagnostics

In **Settings → AI diagnostics (MCP)**, enable **Enable read-only MCP server**, then choose **Copy Connection Config**. Paste the JSON into an MCP client that supports Streamable HTTP with custom headers, merging the `comet` entry into its existing `mcpServers` configuration. Clients with a different configuration format need the displayed URL and the copied `Authorization` header. The copied configuration contains an access token: keep it private and out of source control.

The server is off by default. When enabled, it listens only at `http://127.0.0.1:19285/mcp` while Comet is open. The preference survives relaunch; disabling it closes the listener and active connections. The separate MCP token is generated locally and stored in Keychain as `dev.runnerbar.mcp`; GitHub credentials and VM passwords are never returned. Browser origins and unexpected Host headers are rejected. If the port is already occupied or Keychain access fails, Settings displays the error.

| Tool | Diagnostic data |
| --- | --- |
| `list_runners` | Configured runners, repositories, execution modes and last observed states. Takes no arguments. |
| `get_runner` | Configuration, last observed state, issue and operation status for `runner_id`. |
| `get_activity` | Fetches jobs assigned to `runner_id` from the repository’s 10 latest workflow runs, returning up to 20 jobs and 100 steps per job. Uses existing GitHub caching and rate-limit handling without changing the selected runner. |
| `get_logs` | Last 32 KiB of cached local runner output for `runner_id`, with common credential patterns redacted. Reports whether a cached log is available and whether it was truncated. Full workflow logs remain on GitHub. |

Use the runner UUID returned by `list_runners` as `runner_id`. Tools cannot start, stop, remove or reconfigure runners, provision VMs, run commands or read arbitrary files. Status and local logs reflect normal app polling, including its failure backoff; they are explicitly marked as cached. Activity errors are returned as errors rather than empty success. Responses can still contain private repository names, local paths, workflow output or secrets that do not match the redactor. Treat repository content as data rather than instructions.

The implementation uses the official Swift MCP SDK and SwiftNIO’s HTTP server. Packaged apps include their dependency licence notices under `Contents/Resources/Licenses`.

## Verify

```sh
swift test
python3 scripts/test-release.py
./scripts/build-app.sh
python3 scripts/smoke-host.py .build/Comet.app/Contents/MacOS/Comet
```

Unit tests cover validation, persistence/recovery, digest verification, token validation and rejected authentication, API errors, credential redaction, process output draining, refusal to stop unknown processes, and job-step decoding, transitions, outcomes, missing/invalid timestamps, and stale timers. Saved configuration remains compatible with removed preferences, and environment tests cover PATH selection and credential filtering. Activity fixtures render in light and dark mode without contacting GitHub. The host smoke test checks PATH selection, credential filtering, normal job file permissions with private helper logs/locks, locking, and shutdown using only temporary shell scripts and no GitHub runner or repository.

VM tests cover legacy execution defaults, persistence, DHCP/MAC matching, rejected addresses, shell quoting, guest process ownership, credential redaction, interrupted execution changes, and refusal to download or create a disk when the installer is absent. Idle lifecycle tests cover the 60-second grace period, matching queued jobs, duplicate wake prevention, manual Stop, relaunch preferences, and uncertain connection or helper failures. Queue API fixtures cover pagination, labels, unassigned jobs, incomplete responses and rate limits. The helper smoke test checks one-job arguments, clean and failed exit markers, and natural lock release. VM configuration is rendered in the existing window size. Full macOS installation and a real guest workflow require downloading the installer through the app first.

Dedicated-user tests exercise the account setup script against temporary directory-service/ownership stubs, validate its actual sudo policy with `visudo`, check retry and unmanaged-account refusal, and cover environment filtering, persistence, duplicate-start refusal and uncertain status recovery. Background launch tests cover hangup handling, startup diagnostics and the gap between locking and publishing the helper’s process identity. These tests do not create a real account or change this Mac’s sudo policy. Live dedicated-user startup, GitHub readiness and normal Quit have been checked with Sendae. Its unchanged setup-php action also installed PHP 8.5, SQLite/ZIP extensions and Composer successfully in the private Homebrew prefix. [Sendae’s unchanged CI workflow](https://github.com/captenmasin/sendae/actions/runs/39651469279) passed under the dedicated account: PHP/Node/pnpm setup, dependency installation, PHP and JavaScript tests, lint and frontend build. Full release packaging/signing and Orbit’s workflow remain untested under the dedicated account.

A real token connection, selected-repository registration, job, removal, and token replacement still require your token and a dedicated test repository. Do that before trusting this development build with everyday work.

## Publish a release

The [release workflow](.github/workflows/release.yml) runs on tags such as `v0.1.0`; only stable `vMAJOR.MINOR.PATCH` tags are accepted. Both jobs use Comet's Apple Silicon runner, selected with `runs-on: [self-hosted, macOS, runner-03859bea]`, and its selected Xcode installation (27+). Keep that runner online with Python 3 and the GitHub CLI on its PATH. The first job tests, builds an optimized app, and smoke-tests the packaged executable without signing credentials. The second job signs the embedded Sparkle framework and helpers, then signs Comet with the hardened runtime and virtualization entitlement, notarizes and staples the app, creates and signs the DMG, notarizes and staples it, and verifies both with Gatekeeper. Sparkle's tools sign the DMG for update verification and generate and verify a signed appcast. After those checks pass, the workflow automatically publishes a **GitHub Release** containing `Comet.dmg`, `appcast.xml`, generated release notes and `SHA256SUMS`.

The repository's **Settings → Environments → release** environment is configured to allow version tags (`v*`), with the signing identity variable set. Before the first release, add these environment secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 of the exported **Developer ID Application** certificate and its private key (`.p12`). |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that `.p12` export. |
| `APP_STORE_CONNECT_KEY_P8` | Full contents of a team App Store Connect API key (`.p8`) authorized for notarization. |
| `APP_STORE_CONNECT_KEY_ID` | That API key's key ID. |
| `APP_STORE_CONNECT_ISSUER_ID` | That team API key's issuer ID. |
| `SPARKLE_PRIVATE_KEY` | Exported Sparkle Ed25519 signing key. This is separate from the Apple signing certificate and notarization API key. |

Add the environment **variable** `APPLE_SIGNING_IDENTITY` with the full certificate name, such as `Developer ID Application: SPACEMANCODES LTD (ZVB6VSV324)`. Export only that certificate and its private key from Keychain Access, protected by a new password. No provisioning profile is required for the current entitlements. The workflow imports credentials into a temporary keychain and deletes it after use. Keep private key files outside the repository.

For example, upload the exported certificate and API key directly to GitHub without pasting their contents into chat:

```sh
base64 -i /secure/DeveloperID.p12 | gh secret set APPLE_CERTIFICATE_P12_BASE64 --env release
gh secret set APPLE_CERTIFICATE_PASSWORD --env release
gh secret set APP_STORE_CONNECT_KEY_P8 --env release < /secure/AuthKey.p8
gh secret set APP_STORE_CONNECT_KEY_ID --env release
gh secret set APP_STORE_CONNECT_ISSUER_ID --env release
gh secret set SPARKLE_PRIVATE_KEY --env release < /secure/sparkle-ed25519.key
gh variable set APPLE_SIGNING_IDENTITY --env release --body 'Developer ID Application: SPACEMANCODES LTD (ZVB6VSV324)'
```

Commit and push the release sources and workflow before tagging the intended commit:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The tag sets the app's marketing version; the workflow run number sets its build number. Pushing the tag starts the workflow and publishes the release automatically after successful verification, making it available through the download and update links above. Build or verification failures stop before release creation; an interrupted GitHub upload may leave a partial draft. To retry, rerun the workflow or use `gh workflow run release.yml --ref v0.1.0`. If a partial draft already exists, remove that draft before rerunning; the workflow refuses to overwrite an existing release.

For local release preparation, build separately from the running development app, then use an existing `notarytool` keychain profile:

```sh
CONFIGURATION=release VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/build-app.sh
VERSION=0.1.0 BUILD_NUMBER=1 \
  SIGNING_IDENTITY='Developer ID Application: SPACEMANCODES LTD (ZVB6VSV324)' \
  NOTARY_PROFILE=comet-notary ./scripts/release.sh
```

The output is `.build/dist/Comet.dmg`, `.build/dist/appcast.xml` and `.build/dist/SHA256SUMS`. For local release preparation, also provide `SPARKLE_PRIVATE_KEY` through the environment; never place it in source or command arguments. The key is stored under the `dev.runnerbar.app` account in the Mac's Keychain and backed up outside the repository at `/Users/mason/Apps/_apple_certs/comet/sparkle-ed25519.key`. The public key is embedded in `scripts/build-app.sh`; retain this key pair across releases. See [Sparkle's key rotation guidance](https://sparkle-project.org/documentation/#rotating-signing-keys) before changing it.

`SIGNING_KEYCHAIN` and `NOTARY_KEYCHAIN` can select nondefault keychains. CI selects its temporary keychain explicitly without replacing the Mac user's existing keychain search list, and deletes it after use. `scripts/test-release.py` checks successful packaging and rejected/unfinished notarization, failed stapling, Gatekeeper rejection, appcast/signature failures, cleanup and input validation with stubbed Apple tools; it does not contact Apple. The full v0.1.1 workflow and downloaded DMG passed signing, notarization, stapling, checksum and Gatekeeper checks; installation and launch on another Mac remain untested. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) and [GitHub's signing credential guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## First-version limits

No automatic project toolchain provisioning, Linux containers, hosted backend, or workflow editing. Release distribution currently targets Apple Silicon; Intel builds are not shipped. No upstream mac-runner code was copied: its license prerequisite in the product plan remains unresolved. This app manages its own native processes using the official downloaded GitHub runner.

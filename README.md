# Comet

Comet is a native Mac app for running GitHub Actions on your own Mac. Add runners for trusted repositories, manage them from the menu bar, and open the main window for job activity, logs, and configuration.

Run jobs in your own account, a dedicated user account, or a macOS virtual machine. Comet downloads and verifies the official GitHub runner, registers it, and manages its lifecycle.

## Install

[Download Comet.dmg](https://github.com/captenmasin/comet/releases/latest/download/Comet.dmg), open it, and drag Comet into Applications.

- **Requirements:** Apple Silicon and macOS 15 or later. Automatic macOS VM setup requires macOS 27 or later.
- **Distribution:** The app and DMG are Developer ID signed, notarized by Apple, and stapled for offline verification.
- **Updates:** [Sparkle](https://sparkle-project.org/) checks for and downloads signed updates from GitHub Releases. Use **Check for Updates…** in the Comet menu or menu-bar overflow; change automatic update preferences in Settings. Installation waits for runners to stop and setup to finish, preserving configuration, credentials, workspaces, and VM disks.

Version 0.1.1 and earlier need one manual installation to gain the updater. Development builds do not start it. Intel builds are not distributed.

## Add your first runner

**Only use repositories and workflows you trust.** Current-user jobs run with your permissions. Dedicated-user jobs have unrestricted root access through sudo. VM jobs can become root inside the guest.

1. Choose **Add Runner** and acknowledge the workflow trust requirement.
2. Choose **Create a token on GitHub**. The form preselects **Administration: read and write** and **Actions: read**. Choose an expiry, select the resource owner, and use **Only select repositories** to limit access to repositories you administer.
3. Generate the token, paste it into Comet, and choose **Connect GitHub**. Comet validates it and saves it in macOS Keychain.
4. Select a repository, give the runner a unique name, choose an execution mode, and select **Add and Start Runner**. Dedicated-user and VM execution need the additional setup described below.
5. Open **Configuration → Workflow Snippet** and copy the generated `runs-on` label into your workflow. Comet does not edit workflows.

Your GitHub account needs repository admin access. Fine-grained tokens cover one resource owner and may need organization approval; outside-collaborator access has GitHub limitations. Classic tokens also work, but fine-grained tokens let you restrict repository access. See GitHub’s [token guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) and [runner API permissions](https://docs.github.com/en/rest/actions/self-hosted-runners).

Replace an expired or revoked token in **Settings → Replace Token**. Failed validation preserves the previous token. Comet stores one GitHub management token; replacing it does not revoke the old token on GitHub. To disconnect fully, stop and remove runners, revoke the token on GitHub, and delete `dev.runnerbar.github` in Keychain Access. Keep tokens out of chat and source files.

## Execution modes

| Mode | Runs as | Setup and limits |
| --- | --- | --- |
| Current user | Your Mac account | Uses your local tools and permissions. |
| Dedicated user (sudo) | Hidden `_comet` account | Requires administrator approval. Separate home, caches, keychains, and Homebrew; workflows have unrestricted host root access. |
| macOS VM | `comet` account inside a VM | Requires Apple Silicon, macOS 27+, a macOS installer, and at least 80 GB free. Tools and workspaces persist between jobs. |

### Dedicated user

Choose **Execution → Dedicated user (sudo)**. The first start, or **Set Up Dedicated User…**, requests administrator approval to create `_comet` with password login disabled and install validated sudo rules. Setup refuses to adopt an unmanaged account or home.

Comet installs a separate Homebrew at `/opt/comet-hb` on Apple Silicon or `/opt/comet` on Intel. The dedicated PATH includes this installation, `_comet`’s `~/.local/bin`, and system tools. Workflows install their own packages; tools persist and are shared by all dedicated runners, so concurrent tool setup or keychain changes can conflict. This mode does not create a logged-in desktop session.

**The dedicated account separates everyday files and configuration, but its sudo access does not protect the host or your personal files from workflows.** Removing a runner preserves the account and sudo rules. To revoke those permissions, stop all dedicated runners and remove `/private/etc/sudoers.d/comet` with administrator privileges.

### macOS VM

Choose **Execution → macOS VM**, then **Download macOS…** to fetch the installer from Apple. The download is approximately 27 GB, can be cancelled, and is cached for reuse. Choosing VM execution alone does not download it.

After downloading, choose **Set Up VM…**. Comet uses Apple’s Virtualization framework to install macOS on a 64 GB sparse disk with four CPUs and at least 4 GB RAM. It provisions the guest account, Command Line Tools, Homebrew, and a passwordless sudo rule. Workflows install their remaining tools. Use **Copy VM Password** when an installer needs it; required Apple licence acceptance is reported for you to complete.

VM passwords stay in Keychain, and the GitHub management token stays on the host. Comet connects over SSH with a per-VM known-hosts file. No host folders, clipboard, or agent sockets are shared. NAT networking permits access to reachable network services.

Starting a VM runner enables queue watching while Comet is open. Comet checks every 30 seconds, wakes a compatible VM for queued work, and shuts it down after roughly 60 idle seconds. **Sleeping** means queue watching is enabled. Manual Stop disables watching across relaunches; normal Quit preserves it. Queued jobs wait while Comet is closed. Uncertain job or connection state can leave a VM running to avoid interrupting work.

Closing the VM window leaves it running. Stop and normal Quit request guest shutdown; force-quitting can interrupt guest disk writes. VMs retain their tools and workspaces between jobs and are not reset automatically. Installer images and disks are not pruned.

## Development

Requires Xcode 27 or later. The deployment target is macOS 15; Intel and macOS 15 runtime support have not been validated.

```sh
./scripts/run.sh
```

This builds an ad-hoc signed app at `.build/Comet.app` and opens it. You can also open `Package.swift` in Xcode. SwiftPM resolves dependencies from `Package.resolved`; app users do not need the GitHub CLI. Development rebuilds may prompt for Keychain access again.

Quit Comet before rebuilding its app bundle. Use `scripts/build-app.sh` for appearance checks and VM execution: it records the selected SDK correctly and includes the virtualization entitlement. To preview the running-job icon in a stopped development app:

```sh
open .build/Comet.app --args --simulate-running-job
```

### Verify

```sh
swift test
python3 scripts/test-release.py
./scripts/build-app.sh
python3 scripts/smoke-host.py .build/Comet.app/Contents/MacOS/Comet
```

Unit tests cover configuration, credentials, runner recovery, GitHub responses, activity, execution modes, and VM queue watching. Release tests use stubbed Apple tools. The host smoke test uses temporary shell scripts without a GitHub runner or repository; dedicated-user tests do not create an account or change the Mac’s sudo policy.

End-to-end verification needs a token and a trusted test repository. Full VM verification also needs the downloaded macOS installer. Release installation and launch on another Mac remain unvalidated.

### Artwork

- Edit `Artwork/Comet.icon` with Icon Composer; `scripts/build-app.sh` compiles it and includes the fallback icon.
- Run `swift scripts/generate-icons.swift` to regenerate the menu bar glyphs.
- Run `swift scripts/generate-installer-background.swift` to regenerate the Retina DMG background.
- Run `python3 scripts/generate-installer-layout.py` in a temporary environment with `ds-store==1.3.3` to regenerate Finder layout metadata. Keep the 660 × 360 point background, icon positions, `Comet` volume name, and `.background/background.png` path in sync.

### Releases

The [release workflow](.github/workflows/release.yml) accepts stable `vMAJOR.MINOR.PATCH` tags. It tests, builds, smoke-tests, signs, notarizes, staples, and verifies the app and DMG, then publishes a GitHub Release with `Comet.dmg`, the signed `appcast.xml`, `SHA256SUMS`, and generated release notes. Both jobs use the self-hosted Apple Silicon runner selected in the workflow; keep it online with Xcode 27+, Python 3, and the GitHub CLI available.

Configure the GitHub **release** environment to allow version tags (`v*`) and add these secrets:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`). |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the `.p12` export. |
| `APP_STORE_CONNECT_KEY_P8` | Contents of a team App Store Connect API key authorized for notarization. |
| `APP_STORE_CONNECT_KEY_ID` | API key ID. |
| `APP_STORE_CONNECT_ISSUER_ID` | Team API key issuer ID. |
| `SPARKLE_PRIVATE_KEY` | Exported Sparkle Ed25519 signing key. |

Set the environment **variable** `APPLE_SIGNING_IDENTITY` to the full `Developer ID Application: …` certificate name. No provisioning profile is required. CI imports credentials into a temporary keychain and deletes it after use. Keep private keys outside the repository and retain the Sparkle key pair across releases; its public key is embedded in `scripts/build-app.sh`.

Commit and push the release sources before tagging the intended commit. Replace the example below with the next release version:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The tag sets the app version; the workflow run number sets the build number. Publishing happens automatically after verification. Rerun a failed workflow to retry. If an interrupted upload left a partial draft, remove that draft first: the workflow refuses to overwrite an existing release.

For local packaging, provide `SPARKLE_PRIVATE_KEY` through the environment, use your Developer ID identity and an existing `notarytool` keychain profile, and set the intended version and build number:

```sh
CONFIGURATION=release VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/build-app.sh
VERSION=0.1.0 BUILD_NUMBER=1 \
  SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  NOTARY_PROFILE=comet-notary ./scripts/release.sh
```

Outputs are in `.build/dist/`. `SIGNING_KEYCHAIN` and `NOTARY_KEYCHAIN` select nondefault keychains. See [Apple’s notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GitHub’s signing credential guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications), and [Sparkle’s key rotation guidance](https://sparkle-project.org/documentation/#rotating-signing-keys).

# 🚀 Pow: The Ultimate PowerShell Profile Framework

![PowerShell 7+](https://img.shields.io/badge/PowerShell-7.0+-blue.svg?style=for-the-badge&logo=powershell)
![Platform Compatibility](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20macOS-lightgrey.svg?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)

> **Supercharge your terminal experience with a modular, auto-provisioning, and cross-platform PowerShell profile designed for elite systems engineers.**

![Terminal Demo](assets/demo.gif)
*(Placeholder for your amazing terminal aesthetic demo)*

## 📑 Table of Contents

1. [Architecture & Framework Overview](#-architecture--framework-overview)
2. [Installation & Quick Start](#-installation--quick-start)
3. [Feature & Function Deep-Dive](#-feature--function-deep-dive)
    * [Configuration Management](#configuration-management)
    * [Environment & Validation](#environment--validation)
    * [Structured Logging](#structured-logging)
    * [Security & Repositories](#security--repositories)
    * [Module & Provisioning Engine](#module--provisioning-engine)

---

## 🏗️ Architecture & Framework Overview

**Pow** isn't just a `$PROFILE` script; it is a full-fledged environment orchestrator. Built with performance, security, and aesthetics in mind, this profile revolutionizes your daily workflow by:
* **Asynchronous & Deferred Loading:** Ensures your prompt appears instantly by deferring heavy module imports to run in the background.
* **Cross-Platform Intelligence:** Gracefully adapts its logic (like checking `Test-Admin` privileges or pinging networks) depending on whether you are running Windows, macOS, or Linux.
* **Idempotent Auto-Provisioning:** Seamlessly detects missing dependencies (like `oh-my-posh`, `PSReadLine`) and installs them on the first run using the best available package provider.
* **Stateful Configuration:** Caches your preferences, module states, and environment metadata locally, reducing startup latency to absolute zero on subsequent launches.

---

## 🚀 Installation & Quick Start

Get your new terminal up and running in seconds:

```powershell
# 1. Clone the repository into your local workspace
git clone https://github.com/DrMaig/Pow.git "$HOME/Documents/Pow"

# 2. Back up your existing profile
if (Test-Path $PROFILE) { Copy-Item $PROFILE "$PROFILE.bak" -Force }

# 3. Link or copy the Pow profile to your native path
Copy-Item "$HOME/Documents/Pow/Microsoft.PowerShell_profile.ps1" $PROFILE -Force

# 4. Reload your terminal (Pow will automatically provision dependencies on first run!)
. $PROFILE
```

---

## 🛠️ Feature & Function Deep-Dive

Below is the comprehensive list of core functions powering the framework, documented strictly for system administrators and power users.

### Configuration Management

#### `Save-ProfileConfig`
* **Concept & Workflow:** Acts as the persistence layer for your terminal environment. Rather than hard-coding preferences in your `$PROFILE`, this tool serializes the `$Global:ProfileConfig` state object into a local JSON cache. This enables dynamic customization of UI components, logging thresholds, and module loading behavior on the fly without ever editing raw script files.
* **Arguments & Switches:** 
  * `-Path [string]`: (Optional) Overrides the default save destination. Defaults to `$Global:ProfileConfig.CachePath\profile_config.json`.
* **Expected Output:** Returns `$true` on success and logs the execution. The configuration is written to disk in UTF8-encoded JSON.

#### `Invoke-ProfileConfig`
* **Concept & Workflow:** The hydration engine for the profile. Executed silently during terminal startup, it reads the persisted JSON configuration file and performs a shallow merge over the safe default settings. This guarantees that your custom preferences (e.g., prompt style, editor choice) are instantly restored while preserving fallback defaults for missing keys.
* **Arguments & Switches:**
  * `-Path [string]`: (Optional) The target JSON file to read from.
* **Expected Output:** Returns `$true` if custom configurations were successfully loaded and applied to the global session state.

### Environment & Validation

#### `Test-Admin`
* **Concept & Workflow:** A truly cross-platform privilege escalation detector. On Windows, it leverages the native `.NET` security principal classes to check for the `Administrator` role. On Unix systems (Linux/macOS), it gracefully falls back to checking the effective user ID (`uid 0`) or `SUDO_UID` environment variables. 
* **Arguments & Switches:** None.
* **Expected Output:** Returns a boolean (`$true` or `$false`) representing the current administrative context.

#### `Test-Environment`
* **Concept & Workflow:** The diagnostic heartbeat of the profile. It builds a `$Global:ProfileState` telemetry object by scanning the OS platform, PowerShell version, network reachability, administrative rights, and the presence of essential command-line tools (`winget`, `pwsh`, `code`, etc.). This data dictates how downstream provisioning scripts behave.
* **Arguments & Switches:**
  * `-SkipNetworkCheck [switch]`: Bypasses the DNS/TCP probe. Useful for maximizing startup speed or operating in air-gapped environments.
* **Expected Output:** Returns and updates the `$Global:ProfileState` object containing rich environment metadata.

#### `Show-EnvironmentReport`
* **Concept & Workflow:** A front-end visualizer for the diagnostic data gathered by `Test-Environment`. It prints a beautifully formatted summary of the terminal's current capability state to the console, allowing engineers to instantly spot missing dependencies or privilege issues.
* **Arguments & Switches:**
  * `-VerboseReport [switch]`: Prints additional background notes and error catches encountered during the environment validation.
* **Expected Output:** A color-coded summary printed to the host console detailing OS version, admin rights, network status, and missing tools.

### Structured Logging

#### `Write-ProfileLog`
* **Concept & Workflow:** A thread-safe, structured logging facility. It writes runtime events (errors, module loads, config updates) to rolling monthly log files. It filters outputs based on your configured log level (e.g., `DEBUG` vs. `INFO`) and safely uses temporary files for atomic writes, ensuring logs are never corrupted during concurrent terminal launches.
* **Arguments & Switches:**
  * `-Message [string]` (Mandatory): The payload message.
  * `-Level [string]`: The severity level (`INFO`, `WARN`, `ERROR`, `DEBUG`, `SUCCESS`).
  * `-Prefix [string]`: (Optional) Log file prefix, defaults to `profile`.
* **Expected Output:** Persists a compressed JSON log entry to disk and, depending on the severity and config, prints a color-coded output to the terminal.

#### `Watch-ProfileLog`
* **Concept & Workflow:** A convenience wrapper around `Get-Content -Wait`. Ideal for debugging background jobs or deferred module loading by streaming the live profile logs directly to the user's console in real time.
* **Arguments & Switches:**
  * `-Prefix [string]`: Target the specific log stream.
* **Expected Output:** A live, tailing output of the specified log file.

### Security & Repositories

#### `Register-RepositoryInteractive`
* **Concept & Workflow:** A secure, consent-driven repository management tool. Instead of blindly trusting external sources, this function forces an interactive prompt, requiring the user to explicitly confirm before registering new `PSGallery` or private artifact feeds. It logs the consent and saves the repository to a trusted cache.
* **Arguments & Switches:**
  * `-Name [string]` (Mandatory): The repository moniker.
  * `-SourceLocation [string]` (Mandatory): The URI of the repository.
  * `-Credential [PSCredential]`: (Optional) Credentials for private feeds.
  * `-InstallationPolicy [string]`: Policy enforcement, strictly defaulting to `Trusted`.
* **Expected Output:** Returns `$true` after successfully mapping the repository and caching its trusted status.

### Module & Provisioning Engine

#### `Get-ModulePlan`
* **Concept & Workflow:** An intelligent dependency resolver. It accepts an array of desired PowerShell modules (with minimum version constraints) and compares them against a locally cached list of installed modules. It then generates an actionable, idempotent execution plan detailing exactly which modules need to be installed, updated, or skipped.
* **Arguments & Switches:**
  * `-DesiredModules [array]` (Mandatory): An array of hashtables outlining module names, required versions, and strictness.
* **Expected Output:** Returns an ordered array of planned actions (e.g., `Action='Install'|'Update'|'Skip'|'NoneNeeded'`).

#### `Invoke-FirstRunProvisioning`
* **Concept & Workflow:** The magic behind the "zero-to-hero" setup. On the very first launch of the terminal, this engine consumes the plan generated by `Get-ProfileModulePlan`. It automatically connects to the internet, negotiates package providers (`PSResourceGet` or `PowerShellGet`), safely trusts the gallery, and installs all missing aesthetic and functional dependencies (like `oh-my-posh`). It is strictly idempotent and tracks its state to never run unnecessarily twice.
* **Arguments & Switches:** None.
* **Expected Output:** Returns `$true` if provisioning succeeds, injecting paths for newly downloaded binaries and marking the local cache as fully provisioned.
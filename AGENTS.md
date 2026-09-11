# AGENTS.md

> ⚠️ **MANDATORY READ — BEFORE ANY GIT / TEST / DOC OPERATION**
>
> The real rules for this project are NOT all in this file. This project depends on the
> `shell` project, whose agents file lives at `${MY_GIT_DIR}/shell/AGENTS.md` and
> contains the authoritative `## Documentation`, `## Setup & Configuration`,
> `## Testing & Quality Control`, `## Git Workflow Rules` and
> `## Code Style & Conventions` sections. **You MUST read that file before performing
> any of the following actions, and follow the referenced sections with `LIB="tofu"`:**
> - **any `git` command** → `## Git Workflow Rules`
> - **any test / quality gate run** → `## Testing & Quality Control`
> - **any documentation change or sync** → `## Documentation`
> - **any code edit** → `## Code Style & Conventions`
>
> Reading the referenced file is **mandatory, not optional**. A pointer is not
> content — if you did not read `${MY_GIT_DIR}/shell/AGENTS.md` in the current
> session, read it now before acting.

## Project Overview

An **OpenTofu project** provisioning Debian **virtual machines** and **unprivileged LXC
containers** on a **Proxmox VE** node, driven by two maps of objects (`var.vm` and `var.ct`)
so that adding a guest is a `.tfvars` edit instead of a resource copy/paste.

The repository doubles as a **feature library** named `tofu` for the `my_warp.sh`
orchestrator: `lib_tofu.sh` wraps the OpenTofu CLI so the same commands (and their safety
guards) are used locally and from CI.

## Architecture (high level)

* **Base dependency (`lib_shell.sh` from `shell`)**: `lib_tofu.sh` relies on the runtime
  (`_func_start`/`_func_end` telemetry, `_error`/`_success`/`_info`/`_warning`/`_verbose`
  logging, `_exist`/`_fileexist`/`_installed` validation, `$GREP`, `ERROR_ARGV`, the
  `--force`/`--dry-run` globals). The runtime library is loaded first by `my_warp.sh`; this
  project only contains the feature layer.
* **OpenTofu configuration (HCL)**:
  - `providers.tf` — provider version constraint and the `proxmox` provider block (endpoint,
    auth, TLS incl. `min_tls`, temp dir, `ssh`).
  - `variables.tf` — every input variable, grouped by concern, with `validation` rules.
  - `images.tf` — OS images downloaded on the node (`proxmox_virtual_environment_download_file`).
  - `cloud-init.tf` — the two snippet uploads, the rendered payload and the rebuild trigger.
  - `cloud-init/user-config.yaml.tftpl`, `cloud-init/vendor-config.yaml` — user/vendor data.
  - `vms.tf` / `containers.tf` — one VM / container per map entry, with `lifecycle`
    preconditions; `outputs.tf` — guest ids/names/addresses and datastore volume ids.
  - `terraform.tfvars.example`, `conf/tofu.conf` — documented sample values and wrapper defaults.
* **Feature Library (`lib_tofu.sh`)** — orchestrator commands grouped as
  (per-function reference: `functions.md`, auto-generated — never hand-maintained):
  - Runtime — resolve the binary/directory/variable file and run `tofu` (`_tofu_bin`,
    `_tofu_dir`, `_tofu_var_file`, `_tofu_run`), plus the `--force` guard (`_tofu_confirm`).
  - Toolchain commands — `version`, `init`, `fmt`, `validate`.
  - Lifecycle commands — `plan`, `apply`, `destroy`, `output`, `state_list`, `show`
    (`apply`/`destroy` refuse to run without `--force`).
  - Project checks — `check` (fmt + validate) and `vars_doc_check` (variables documented).
  - Orchestrator dispatcher — `_process_lib_tofu`, `_usage_tofu`.
* **Tests (`bats/tests.bats`)**: wrapper behaviour with a mocked `tofu` stub plus the project
  invariants (variable validations, rebuild trigger, documentation sync) driven with the real
  `tofu` binary — both offline.
* **Full user-facing documentation**: `README.md` (including the wrapper command reference).

## Documentation

The documentation and sync rules described in the `## Documentation` section of
`${MY_GIT_DIR}/shell/AGENTS.md` apply here with `lib_shell.sh` → `lib_tofu.sh` and
`--lib shell` → `--lib tofu`. Key points:

* Doc markers in `lib_tofu.sh` (`# usage:`/`# call:`, `# description:`, `# example:`,
  `# return:`, `# doc-section:`) are the source of truth — edit the markers, never
  `functions.md` by hand.
* Regenerate the reference after any marker change and commit it:

  ```shell
  ${MY_GIT_DIR}/shell/my_warp.sh --lib tofu --doc functions.md
  ```

* `bats/tests.bats` must stay in sync with `lib_tofu.sh`: adding a command means adding its
  tests (happy path, validation and error paths, dispatcher routing).
* `README.md` documents the variables, the guests and the wrapper commands;
  `tofu_vars_doc_check` fails when a variable of `variables.tf` is no longer documented in
  `README.md` or `terraform.tfvars.example`.

## Setup & Configuration

Requires the `shell` project, the `my_warp.sh` orchestrator environment, the `tofu` binary
(OpenTofu ≥ 1.6) and, for the Proxmox side, the prerequisites listed in `README.md`
(API token, snippets-enabled datastore, SSH access to the node).

Local config is saved under `$MY_GIT_DIR/tofu/conf/tofu.conf`. `lib_tofu.sh` auto-loads and
exports these variables when not already set (environment wins):

| Variable | Default | Purpose |
|----------|---------|---------|
| `TOFU_BIN` | `tofu` | OpenTofu binary found in `PATH`, or an absolute path. |
| `TOFU_DIR` | `$MY_GIT_DIR/tofu` | Directory holding the `.tf` files. |
| `TOFU_VAR_FILE` | *(empty)* | Variable file used when `--var-file` is not given (`terraform.tfvars` when it exists). |

The infrastructure inputs (`pve_endpoint`, `pve_api_token`, `var.vm`, `var.ct`, ...) belong to
`terraform.tfvars` (git-ignored) — see the Variables section of `README.md`.

## Command-Line Interface (CLI)

All wrapper commands go through the orchestrator — never the raw binaries when a command
exists (see `shell/AGENTS.md` → `## Command-Line Interface (CLI)`):

```shell
${MY_GIT_DIR}/shell/my_warp.sh --lib tofu <command> [--var-file …] [--force] [--dry-run]
```

Read-only and safe to run anywhere: `tofu_version`, `tofu_fmt --dry-run`, `tofu_validate`,
`tofu_plan`, `tofu_output`, `tofu_state_list`, `tofu_show`, `tofu_check`,
`tofu_vars_doc_check`. Mutating: `tofu_apply`, `tofu_destroy` (both require `--force`; under
`--dry-run` they only print the plan) and `tofu_fmt`/`tofu_init` (which write to the project).
The raw `tofu` CLI remains usable for anything not wrapped (`tofu state mv`, `tofu import`, ...).

## Testing & Quality Control

Follow `shell/AGENTS.md` → `## Testing & Quality Control` with `LIB="tofu"` (BATS suite under
`bats/tests.bats`, wrapper-only `-s|-b|-k`, full gate owned by the `code_reviewer` sub-agent),
plus these project-specific rules:

* **Tests never write inside the repository**: mocked-stub tests and the offline `tofu`
  harnesses work in `$BATS_TEST_TMPDIR`; the only repository-touching tests are read-only
  (`fmt -check`, `validate`, `$GREP` assertions).
* **Offline by default**: the suite must pass without network access and without Proxmox
  credentials; tests that need the real `tofu` binary `skip` when it is absent, and the
  `validate` test also `skip`s when `.terraform/` is missing.
* **Mocking**: the library always executes `tofu` through `_tofu_run`, so tests stub the binary
  by pointing `TOFU_BIN` at a script in `$BATS_TEST_TMPDIR/bin` that records its argv.
* **Invariants are tested, not assumed**: the session's HCL guarantees (variable validations,
  `vm_id`/`ct_id` rules, checksum lengths, the cloud-init rebuild trigger, the documentation
  sync) each have a dedicated `@test`.

## Git Workflow Rules

Follow `shell/AGENTS.md` → `## Git Workflow Rules`.

## Code Style & Conventions

Follow `shell/AGENTS.md` → `## Code Style & Conventions` (conventions live in
`agents/rules/shell.md`), plus these project-specific rules:

* **The wrapper never auto-approves**: `tofu_apply`/`tofu_destroy` run `-auto-approve` only
  after an explicit `--force` (or `TOFU_CONFIRM=true`), and `--dry-run` must always stay
  read-only (it also skips `--out`, so a preview never writes a plan file); never add a code
  path that mutates infrastructure from a default invocation.
* **One execution point**: all `tofu` invocations go through `_tofu_run` (so they can be
  stubbed and logged) — no direct `tofu` call elsewhere in the library. `plan`, `apply`,
  `destroy` and `init` always pass `-input=false`, so a missing variable fails instead of
  prompting on stdin.
* **`--var-file` is resolved to an absolute path** (relative paths are looked up in
  `TOFU_DIR` first, where `tofu -chdir` resolves them): the file that was validated is the
  file that is passed to `-var-file=`.
* **Quoting and results**: `local` variables use the double-underscore prefix, globals are
  upper-case, functions that output data fill `__result` and print it with `echo "$__result"`.
* **HCL style**: keep the configuration `tofu fmt`-clean (`tofu_fmt --dry-run` is part of the
  gate) and keep every variable documented (README + `terraform.tfvars.example`).
* **Secrets**: never commit `terraform.tfvars`, state files or plan files; the API token and
  passwords stay in the environment or in the git-ignored variable file.

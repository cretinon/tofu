# `lib_tofu.sh` — Function Reference

This document describes every function defined in `lib_tofu.sh`.

> **General conventions**
> - Functions whose name starts with a single underscore (e.g. `_tofu_fmt`) are library functions.
> - Every instrumented function calls `_func_start` at its entry point (passing `"$@"` when arguments are used) and `_func_end "<code>" ; return <code>` before **every** return (including error and early-exit paths), keeping the `FUNC_LIST` telemetry stack balanced.
> - Exit code `0` means success, `1` means generic error/failure, and `10` (`ERROR_ARGV`) means argument/validation error.
> - The library requires the shell runtime (`lib_shell.sh` from the `shell` project) to be loaded first. It relies on the runtime helpers `_func_start`/`_func_end`, `_error`/`_success`/`_info`/`_warning`/`_verbose`, `_exist`/`_fileexist`/`_installed`, `$GREP` and `ERROR_ARGV`.
> - The two commands that write to the infrastructure (`tofu_apply`, `tofu_destroy`) require the orchestrator's `--force` flag; `--dry-run` turns them into a read-only plan preview.

---

## Configuration auto-load

### `conf/tofu.conf`
1. **Description:** At library load time, when `MY_GIT_DIR` is set and `$MY_GIT_DIR/tofu/conf/tofu.conf` exists, that file is sourced and `TOFU_BIN` / `TOFU_DIR` / `TOFU_VAR_FILE` / `TOFU_GPG_BIN` / `TOFU_VARS_GPG_FILE` are exported -- but only when they are not already set in the environment (the environment always wins).
2. **Usage:**
   - `TOFU_BIN` (string): OpenTofu binary name found in `PATH`, or an absolute path (default `tofu`).
   - `TOFU_DIR` (string): directory holding the `.tf` files (default `$MY_GIT_DIR/tofu`).
   - `TOFU_VAR_FILE` (string): variable file used when `--var-file` is not given (default: `terraform.tfvars`, only when that file exists).
   - `TOFU_GPG_BIN` (string): GnuPG binary name found in `PATH`, or an absolute path (default `gpg`).
   - `TOFU_VARS_GPG_FILE` (string): encrypted variable file decrypted on the fly (default `terraform.tfvars.gpg` in the project directory).
3. **Returns:** N/A (variables).

---

## Runtime

### `_tofu_bin`
1. **Description:** Resolves the OpenTofu binary from `TOFU_BIN` (default `tofu`) and checks it is usable.
2. **Usage:**
   - `_tofu_bin` — outputs `tofu` or `/usr/bin/tofu`
3. **Returns:**
   - `0` — the binary is usable; outputs its name/path on stdout
   - `10` (`ERROR_ARGV`) — no usable `tofu` binary found

### `_tofu_dir`
1. **Description:** Resolves the OpenTofu project directory from `TOFU_DIR` (default `$MY_GIT_DIR/tofu`) and checks it holds at least one `.tf` file.
2. **Usage:**
   - `_tofu_dir` — outputs `/root/git/tofu`
3. **Returns:**
   - `0` — the directory is usable; outputs its path on stdout
   - `10` (`ERROR_ARGV`) — directory unset/inexistent, or no `.tf` file inside

### `_tofu_var_file`
1. **Description:** Resolves the variable file to use: `$1` when given, `TOFU_VAR_FILE` otherwise, then the encrypted `terraform.tfvars.gpg` and finally `terraform.tfvars`, and prints it as an absolute path -- a relative path is looked up in the project directory first, exactly where `tofu -chdir` resolves it. An encrypted file is returned as-is: `_tofu_var_decrypt` turns it into a temporary plaintext file. An unset/empty value is accepted (no variable file).
2. **Usage:**
   - `_tofu_var_file "prod.tfvars"` — outputs the absolute path of the file, wherever it was found
   - `_tofu_var_file` — outputs the absolute path of `terraform.tfvars.gpg` (else `terraform.tfvars`) when present in the project, otherwise nothing
3. **Returns:**
   - `0` — variable file resolved; outputs its absolute path (possibly empty) on stdout
   - `10` (`ERROR_ARGV`) — the requested/configured path does not exist or is a directory

### `_tofu_gpg_bin`
1. **Description:** Resolves the GnuPG binary from `TOFU_GPG_BIN` (default `gpg`) and checks it is usable.
2. **Usage:**
   - `_tofu_gpg_bin` — outputs `gpg` or `/usr/bin/gpg`
3. **Returns:**
   - `0` — the binary is usable; outputs its name/path on stdout
   - `10` (`ERROR_ARGV`) — no usable `gpg` binary found

### `_tofu_vars_gpg_file`
1. **Description:** Resolves the encrypted variable file from `TOFU_VARS_GPG_FILE` (a relative path is looked up in the project directory), defaulting to `terraform.tfvars.gpg`, and outputs it only when that file exists.
2. **Usage:**
   - `_tofu_vars_gpg_file` — outputs `/root/git/tofu/terraform.tfvars.gpg` when the file exists, nothing otherwise
3. **Returns:**
   - `0` — resolution done; outputs the absolute path, or nothing when no encrypted variable file is found
   - `10` (`ERROR_ARGV`) — no usable project directory, or the configured path is missing/a directory

### `_tofu_gpg_decrypt`
1. **Description:** Decrypts an OpenPGP file with GnuPG into `$2` (mode `600`) without ever echoing its content, and fails when GnuPG fails: the caller must not fall back to another variable file.
2. **Usage:**
   - `_tofu_gpg_decrypt "$TOFU_DIR/terraform.tfvars.gpg" "/tmp/tofu-varfile.A1b2C3"`
3. **Returns:**
   - `0` — the file was decrypted into `$2`
   - `10` (`ERROR_ARGV`) — `$2` empty, `$1` missing/not a file, or no usable `gpg` binary
   - `1` — GnuPG could not decrypt (wrong/refused passphrase, missing key, corrupt file)

### `_tofu_gpg_encrypt`
1. **Description:** Encrypts a file with GnuPG using a passphrase (`--symmetric`, AES256) into `$2` (mode `600`): the passphrase is asked on the terminal, so no keyring, agent or pinentry program is involved.
2. **Usage:**
   - `_tofu_gpg_encrypt "$TOFU_DIR/terraform.tfvars" "$TOFU_DIR/terraform.tfvars.gpg"`
3. **Returns:**
   - `0` — the file was encrypted into `$2`
   - `10` (`ERROR_ARGV`) — `$2` empty, `$1` missing/not a file, or no usable `gpg` binary
   - `1` — GnuPG could not encrypt (passphrase refused, cancelled, ...)

### `_tofu_var_decrypt`
1. **Description:** Outputs the variable file to hand to `-var-file`: `$1` unchanged when it is a plain `*.tfvars`, or `$2` once an OpenPGP `*.gpg` file has been decrypted into it. Empty in, empty out (no variable file).
2. **Usage:**
   - `_tofu_var_decrypt "terraform.tfvars.gpg" "/tmp/tofu-varfile.A1b2C3"` — outputs the temporary plaintext path
3. **Returns:**
   - `0` — the path to use was output on stdout (possibly empty)
   - `10` (`ERROR_ARGV`) — no usable `gpg` binary for an encrypted file
   - `1` — the decryption failed

### `_tofu_var_cleanup`
1. **Description:** Removes the temporary plaintext file created for an encrypted variable file (`no-op` when `$1` is empty), and never touches anything else.
2. **Usage:**
   - `_tofu_var_cleanup "/tmp/tofu-varfile.A1b2C3"` — removes that file
3. **Returns:**
   - `0` — the temporary file is gone (or there was none)

### `_tofu_run`
1. **Description:** Runs the resolved `tofu` binary inside the project directory (`-chdir`) and outputs its combined stdout/stderr; this is the only place where the binary is executed, so tests can stub it.
2. **Usage:**
   - `_tofu_run validate`
   - `$@` — arguments forwarded verbatim to `tofu`
3. **Returns:**
   - `0` — the command succeeded
   - `10` (`ERROR_ARGV`) — no usable binary or project directory
   - the exit code of the `tofu` command when it failed

### `_tofu_confirm`
1. **Description:** Guards the mutating commands: it succeeds only when the action was explicitly confirmed with `--force` (`FORCE=true`) or `TOFU_CONFIRM=true`.
2. **Usage:**
   - `_tofu_confirm "apply"` — outputs nothing and returns `0` once `--force` was given
3. **Returns:**
   - `0` — the action is explicitly confirmed
   - `10` (`ERROR_ARGV`) — no confirmation for `$1` (or `$1` empty)

---

## Toolchain Commands

### `_tofu_version`
1. **Description:** Prints the OpenTofu version of the resolved binary (`tofu version`).
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_version`
3. **Returns:**
   - `0` — version printed
   - `10` (`ERROR_ARGV`) — no usable binary or project directory
   - `1` — the `tofu version` command failed.

### `_tofu_init`
1. **Description:** Initializes the working directory (`tofu init`), downloading the providers unless `--backend false` (the default) is passed for an offline `init -backend=false`. Under `--dry-run` the call is only logged.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_init`
   - `my_warp.sh --lib tofu tofu_init --backend true`
3. **Returns:**
   - `0` — initialization succeeded (or was skipped by `--dry-run`)
   - `10` (`ERROR_ARGV`) — `--backend` is not `true`/`false`, or no usable binary/directory
   - `1` — the `tofu init` command failed.

### `_tofu_fmt`
1. **Description:** Formats the project in place (`tofu fmt -recursive`); under `--dry-run` it only checks the formatting (`-check -diff`) and fails when files need a rewrite.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_fmt`
   - `my_warp.sh --lib tofu --dry-run tofu_fmt` — check mode, never writes
3. **Returns:**
   - `0` — formatting applied (or already clean in check mode)
   - `10` (`ERROR_ARGV`) — no usable binary or project directory
   - `1` — the `tofu fmt` command failed.

### `_tofu_validate`
1. **Description:** Validates the configuration (`tofu validate`) against the already installed providers; when it fails, an actionable hint about `tofu_init` is logged.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_validate`
3. **Returns:**
   - `0` — the configuration is valid
   - `10` (`ERROR_ARGV`) — no usable binary or project directory
   - `1` — the `tofu validate` command failed.

---

## Lifecycle Commands

### `_tofu_plan`
1. **Description:** Shows the execution plan (`tofu plan -input=false`), optionally with a variable file and/or saving the plan to a file (keep it out of git: `*.tfplan` is ignored). An encrypted `terraform.tfvars.gpg` is decrypted on the fly into a temporary file. `--dry-run` never writes the plan file.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_plan`
   - `my_warp.sh --lib tofu tofu_plan --out change.tfplan`
3. **Returns:**
   - `0` — the plan was produced
   - `10` (`ERROR_ARGV`) — variable file missing or unusable, or no usable binary/directory
   - `1` — the `tofu plan` command failed, or the encrypted variable file could not be decrypted.

### `_tofu_apply`
1. **Description:** Applies the configuration (`tofu apply -auto-approve`). Requires `--force` (or `TOFU_CONFIRM=true`); under `--dry-run` it only shows the plan. An encrypted `terraform.tfvars.gpg` is decrypted on the fly into a temporary file.
2. **Usage:**
   - `my_warp.sh --lib tofu --force tofu_apply`
   - `my_warp.sh --lib tofu --dry-run tofu_apply` — read-only preview
3. **Returns:**
   - `0` — the apply (or the dry-run plan) succeeded
   - `10` (`ERROR_ARGV`) — no `--force`, invalid variable file, or no usable binary/directory
   - `1` — the `tofu apply` command failed, or the encrypted variable file could not be decrypted.

### `_tofu_destroy`
1. **Description:** Destroys the managed guests (`tofu destroy -auto-approve`). Requires `--force` (or `TOFU_CONFIRM=true`); under `--dry-run` it only shows the destroy plan. An encrypted `terraform.tfvars.gpg` is decrypted on the fly into a temporary file.
2. **Usage:**
   - `my_warp.sh --lib tofu --force tofu_destroy`
   - `my_warp.sh --lib tofu --dry-run tofu_destroy` — read-only preview
3. **Returns:**
   - `0` — the destroy (or the dry-run plan) succeeded
   - `10` (`ERROR_ARGV`) — no `--force`, invalid variable file, or no usable binary/directory
   - `1` — the `tofu destroy` command failed, or the encrypted variable file could not be decrypted.

### `_tofu_output`
1. **Description:** Prints the outputs of the state as JSON (`tofu output -json`), either every output or a single one when `--name` is given.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_output`
   - `my_warp.sh --lib tofu tofu_output --name vm_ids`
3. **Returns:**
   - `0` — outputs printed
   - `10` (`ERROR_ARGV`) — no usable binary or project directory
   - `1` — the `tofu output` command failed.

### `_tofu_state_list`
1. **Description:** Lists the resources recorded in the state (`tofu state list`), one resource address per line.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_state_list`
3. **Returns:**
   - `0` — the state was listed (an empty state is still a success)
   - `10` (`ERROR_ARGV`) — no usable binary or project directory
   - `1` — the `tofu state list` command failed.

### `_tofu_show`
1. **Description:** Shows the current state, or the plan stored in `--file`, as JSON (`tofu show -json`).
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_show`
   - `my_warp.sh --lib tofu tofu_show --file change.tfplan`
3. **Returns:**
   - `0` — the state/plan was printed
   - `10` (`ERROR_ARGV`) — `--file` does not exist, or no usable binary/directory
   - `1` — the `tofu show` command failed.

---

## Project Checks

### `_tofu_check`
1. **Description:** Runs the project quality gate without writing anything: `tofu fmt -check -recursive -diff` first, then `tofu validate` — the first failing step decides the exit code.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_check`
3. **Returns:**
   - `0` — formatting is clean and the configuration validates
   - `10` (`ERROR_ARGV`) — no usable binary or project directory
   - `1` — the format check or the validation failed.

### `_tofu_vars_doc_check`
1. **Description:** Checks that every `variable "<name>"` of `variables.tf` is documented in `README.md` and in `terraform.tfvars.example` (pure offline check, no `tofu` call).
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_vars_doc_check`
3. **Returns:**
   - `0` — every variable is documented in both files
   - `10` (`ERROR_ARGV`) — project directory, `variables.tf` or `README.md` missing
   - `1` — at least one variable is undocumented

### `_tofu_vars_encrypt`
1. **Description:** Encrypts a variable file into a passphrase-protected file with GnuPG (`--symmetric`, AES256, passphrase asked on the terminal) -- bootstrap and tests only: the normal way to edit `terraform.tfvars.gpg` is an EasyPG-capable editor.
2. **Usage:**
   - `my_warp.sh --lib tofu tofu_vars_encrypt` — encrypts terraform.tfvars into terraform.tfvars.gpg
   - `my_warp.sh --lib tofu tofu_vars_encrypt --var-file lab.tfvars --out lab.tfvars.gpg`
3. **Returns:**
   - `0` — the file was encrypted (or would be, under `--dry-run`); outputs the encrypted path
   - `10` (`ERROR_ARGV`) — source file missing, destination already existing without `--force`, or no usable `gpg` binary
   - `1` — GnuPG failed to encrypt (passphrase refused or cancelled).

---

## Orchestrator Dispatcher

### `_usage_tofu`
1. **Description:** Prints the tofu lib help header; the per-command `# usage:` lines themselves are appended by the orchestrator's `_usage`.
2. **Usage:**
   - `my_warp.sh --lib tofu -h`
3. **Returns:**
   - Always `0`. Outputs the help header on stdout.

### `_process_lib_tofu`
1. **Description:** Routes the orchestrator calls to the tofu lib commands, after collecting the `--var-file`, `--out`, `--name`, `--file` and `--backend` options.
2. **Usage:**
   - `_process_lib_tofu "--var-file 'prod.tfvars' -- tofu_plan --"`
3. **Returns:**
   - Always `0` when no command was given (usage is printed); otherwise the exit code of the dispatched command.

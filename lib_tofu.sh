#!/bin/bash

# shellcheck source=/dev/null disable=2001

# doc-top: > **General conventions**
# doc-top: > - Functions whose name starts with a single underscore (e.g. `_tofu_fmt`) are library functions.
# doc-top: > - Every instrumented function calls `_func_start` at its entry point (passing `"$@"` when arguments are used) and `_func_end "<code>" ; return <code>` before **every** return (including error and early-exit paths), keeping the `FUNC_LIST` telemetry stack balanced.
# doc-top: > - Exit code `0` means success, `1` means generic error/failure, and `10` (`ERROR_ARGV`) means argument/validation error.
# doc-top: > - The library requires the shell runtime (`lib_shell.sh` from the `shell` project) to be loaded first. It relies on the runtime helpers `_func_start`/`_func_end`, `_error`/`_success`/`_info`/`_warning`/`_verbose`, `_exist`/`_fileexist`/`_installed`, `$GREP` and `ERROR_ARGV`.
# doc-top: > - The two commands that write to the infrastructure (`tofu_apply`, `tofu_destroy`) require the orchestrator's `--force` flag; `--dry-run` turns them into a read-only plan preview.
# doc-verbatim: ## Configuration auto-load
# doc-verbatim:
# doc-verbatim: ### `conf/tofu.conf`
# doc-verbatim: 1. **Description:** At library load time, when `MY_GIT_DIR` is set and `$MY_GIT_DIR/tofu/conf/tofu.conf` exists, that file is sourced and `TOFU_BIN` / `TOFU_DIR` / `TOFU_VAR_FILE` / `TOFU_GPG_BIN` / `TOFU_VARS_GPG_FILE` are exported -- but only when they are not already set in the environment (the environment always wins).
# doc-verbatim: 2. **Usage:**
# doc-verbatim:    - `TOFU_BIN` (string): OpenTofu binary name found in `PATH`, or an absolute path (default `tofu`).
# doc-verbatim:    - `TOFU_DIR` (string): directory holding the `.tf` files (default `$MY_GIT_DIR/tofu`).
# doc-verbatim:    - `TOFU_VAR_FILE` (string): variable file used when `--var-file` is not given (default: `terraform.tfvars`, only when that file exists).
# doc-verbatim:    - `TOFU_GPG_BIN` (string): GnuPG binary name found in `PATH`, or an absolute path (default `gpg`).
# doc-verbatim:    - `TOFU_VARS_GPG_FILE` (string): encrypted variable file decrypted on the fly (default `terraform.tfvars.gpg` in the project directory).
# doc-verbatim: 3. **Returns:** N/A (variables).
# doc-verbatim:
# doc-verbatim: ---
# doc-verbatim:
if [ -n "$MY_GIT_DIR" ] && [ -f "$MY_GIT_DIR/tofu/conf/tofu.conf" ]; then
    if [ -z "${TOFU_BIN:-}" ] || [ -z "${TOFU_DIR:-}" ] || [ -z "${TOFU_GPG_BIN:-}" ]; then
        source "$MY_GIT_DIR/tofu/conf/tofu.conf"
        export TOFU_BIN
        export TOFU_DIR
        export TOFU_VAR_FILE
        export TOFU_GPG_BIN
        export TOFU_VARS_GPG_FILE
    fi
fi

# doc-section: Runtime
# call: _tofu_bin ()
# description: Resolves the OpenTofu binary from `TOFU_BIN` (default `tofu`) and checks it is usable.
# example: `_tofu_bin` — outputs `tofu` or `/usr/bin/tofu`
# return: `0` — the binary is usable; outputs its name/path on stdout
# return: `10` (`ERROR_ARGV`) — no usable `tofu` binary found
_tofu_bin () {
    _func_start

    local __bin="${TOFU_BIN:-tofu}"
    local __result="${TOFU_BIN:-tofu}"

    if ! _installed "$__bin"; then _error "TOFU_BIN: no usable '$__bin' binary (install OpenTofu or set TOFU_BIN)" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    echo "$__result"

    _func_end "0" ; return 0
}

# call: _tofu_dir ()
# description: Resolves the OpenTofu project directory from `TOFU_DIR` (default `$MY_GIT_DIR/tofu`) and checks it holds at least one `.tf` file.
# example: `_tofu_dir` — outputs `/root/git/tofu`
# return: `0` — the directory is usable; outputs its path on stdout
# return: `10` (`ERROR_ARGV`) — directory unset/inexistent, or no `.tf` file inside
_tofu_dir () {
    _func_start

    local __dir="${TOFU_DIR:-}"
    local __result

    if ! _exist "$__dir"; then __dir="$MY_GIT_DIR/tofu"; fi
    if ! _fileexist "$__dir"; then _error "TOFU_DIR: '$__dir' does not exist" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _exist "$(find "$__dir" -maxdepth 1 -name '*.tf' -print -quit 2>/dev/null)"; then _error "TOFU_DIR: no .tf file found in '$__dir'" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    __result="$__dir"
    echo "$__result"

    _func_end "0" ; return 0
}

# call: _tofu_var_file ($1:var-file)
# description: Resolves the variable file to use: `$1` when given, `TOFU_VAR_FILE` otherwise, then the encrypted `terraform.tfvars.gpg` and finally `terraform.tfvars`, and prints it as an absolute path -- a relative path is looked up in the project directory first, exactly where `tofu -chdir` resolves it. An encrypted file is returned as-is: `_tofu_var_decrypt` turns it into a temporary plaintext file. An unset/empty value is accepted (no variable file).
# example: `_tofu_var_file "prod.tfvars"` — outputs the absolute path of the file, wherever it was found
# example: `_tofu_var_file` — outputs the absolute path of `terraform.tfvars.gpg` (else `terraform.tfvars`) when present in the project, otherwise nothing
# return: `0` — variable file resolved; outputs its absolute path (possibly empty) on stdout
# return: `10` (`ERROR_ARGV`) — the requested/configured path does not exist or is a directory
_tofu_var_file () {
    _func_start "$@"

        local __file="${1:-}"
        local __gpg_file=""
        local __dir
        local __result=""
    
        if ! __dir=$(_tofu_dir); then _error "DIR: no usable tofu project directory" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
        if ! _exist "$__file"; then __file="${TOFU_VAR_FILE:-}" ; fi
        if ! _exist "$__file"; then
            if ! __gpg_file=$(_tofu_vars_gpg_file); then _error "TOFU_VARS_GPG_FILE: invalid encrypted variable file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
        fi
        if ! _exist "$__file"; then
            if _exist "$__gpg_file"; then
                __file="$__gpg_file"
                if _fileexist "$__dir/terraform.tfvars"; then _warning "VAR_FILE: using '$__gpg_file' and ignoring the plaintext '$__dir/terraform.tfvars'" ; fi
            elif _fileexist "$__dir/terraform.tfvars"; then
                __file="terraform.tfvars"
            fi
        fi

    if _exist "$__file"; then
        if _fileexist "$__dir/$__file"; then __file="$__dir/$__file" ; fi
        if ! _fileexist "$__file"; then _error "VAR_FILE: '$__file' not found (looked in '$__dir')" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
        if [ -d "$__file" ]; then _error "VAR_FILE: '$__file' is a directory, not a file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
        __result=$(realpath -- "$__file" 2>/dev/null)
        if ! _exist "$__result"; then __result="$__file" ; fi
    fi

    echo "$__result"

    _func_end "0" ; return 0
}

# call: _tofu_gpg_bin ()
# description: Resolves the GnuPG binary from `TOFU_GPG_BIN` (default `gpg`) and checks it is usable.
# example: `_tofu_gpg_bin` — outputs `gpg` or `/usr/bin/gpg`
# return: `0` — the binary is usable; outputs its name/path on stdout
# return: `10` (`ERROR_ARGV`) — no usable `gpg` binary found
_tofu_gpg_bin () {
    _func_start

    local __bin="${TOFU_GPG_BIN:-gpg}"
    local __result="${TOFU_GPG_BIN:-gpg}"

    if ! _installed "$__bin"; then _error "TOFU_GPG_BIN: no usable '$__bin' binary (install GnuPG or set TOFU_GPG_BIN)" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    echo "$__result"

    _func_end "0" ; return 0
}

# call: _tofu_vars_gpg_file ()
# description: Resolves the encrypted variable file from `TOFU_VARS_GPG_FILE` (a relative path is looked up in the project directory), defaulting to `terraform.tfvars.gpg`, and outputs it only when that file exists.
# example: `_tofu_vars_gpg_file` — outputs `/root/git/tofu/terraform.tfvars.gpg` when the file exists, nothing otherwise
# return: `0` — resolution done; outputs the absolute path, or nothing when no encrypted variable file is found
# return: `10` (`ERROR_ARGV`) — no usable project directory, or the configured path is missing/a directory
_tofu_vars_gpg_file () {
    _func_start

    local __dir
    local __file="${TOFU_VARS_GPG_FILE:-}"
    local __result=""

    if ! __dir=$(_tofu_dir); then _error "DIR: no usable tofu project directory" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    if _exist "$__file"; then
        if ! _fileexist "$__file"; then __file="$__dir/$__file" ; fi
        if ! _fileexist "$__file"; then _error "TOFU_VARS_GPG_FILE: '$__file' not found (looked in '$__dir')" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
        if [ -d "$__file" ]; then _error "TOFU_VARS_GPG_FILE: '$__file' is a directory, not a file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    else
        __file="$__dir/terraform.tfvars.gpg"
        if ! _fileexist "$__file"; then __file="" ; fi
    fi

    if _exist "$__file"; then
        __result=$(realpath -- "$__file" 2>/dev/null)
        if ! _exist "$__result"; then __result="$__file" ; fi
    fi

    echo "$__result"

    _func_end "0" ; return 0
}

# call: _tofu_gpg_decrypt ($1:file) ($2:dest)
# description: Decrypts an OpenPGP file with GnuPG into `$2` (mode `600`) without ever echoing its content, and fails when GnuPG fails: the caller must not fall back to another variable file.
# example: `_tofu_gpg_decrypt "$TOFU_DIR/terraform.tfvars.gpg" "/tmp/tofu-varfile.A1b2C3"`
# return: `0` — the file was decrypted into `$2`
# return: `10` (`ERROR_ARGV`) — `$2` empty, `$1` missing/not a file, or no usable `gpg` binary
# return: `1` — GnuPG could not decrypt (wrong/refused passphrase, missing key, corrupt file)
_tofu_gpg_decrypt () {
    _func_start "$@"

    local __file="${1:-}"
    local __dest="${2:-}"
    local __bin
    local __return=0

    if ! _exist "$__dest"; then _error "DEST: no destination given for the decrypted variable file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _fileexist "$__file"; then _error "FILE: '$__file' not found" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if [ -d "$__file" ]; then _error "FILE: '$__file' is a directory, not a file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! __bin=$(_tofu_gpg_bin); then _error "BIN: no usable gpg binary" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    # Loopback pinentry: GnuPG asks the passphrase on the terminal itself, so no keyring,
    # agent, pinentry program or DISPLAY is involved, and nothing is cached. Its messages
    # are left on the terminal (the passphrase prompt must stay visible); the plaintext
    # goes to $__dest only.
    if ! "$__bin" --yes --pinentry-mode loopback --output "$__dest" --decrypt "$__file" > /dev/null; then
        _error "GPG: could not decrypt '$__file' (wrong passphrase, missing key or corrupt file)" ; __return=1
    fi
    if [ "$__return" == "0" ]; then chmod 600 "$__dest" 2>/dev/null ; fi

    _func_end "$__return" ; return "$__return"
}

# call: _tofu_gpg_encrypt ($1:file) ($2:dest)
# description: Encrypts a file with GnuPG using a passphrase (`--symmetric`, AES256) into `$2` (mode `600`): the passphrase is asked on the terminal, so no keyring, agent or pinentry program is involved.
# example: `_tofu_gpg_encrypt "$TOFU_DIR/terraform.tfvars" "$TOFU_DIR/terraform.tfvars.gpg"`
# return: `0` — the file was encrypted into `$2`
# return: `10` (`ERROR_ARGV`) — `$2` empty, `$1` missing/not a file, or no usable `gpg` binary
# return: `1` — GnuPG could not encrypt (passphrase refused, cancelled, ...)
_tofu_gpg_encrypt () {
    _func_start "$@"

    local __file="${1:-}"
    local __dest="${2:-}"
    local __bin
    local __return=0

    if ! _exist "$__dest"; then _error "DEST: no destination given for the encrypted variable file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _fileexist "$__file"; then _error "FILE: '$__file' not found" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if [ -d "$__file" ]; then _error "FILE: '$__file' is a directory, not a file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! __bin=$(_tofu_gpg_bin); then _error "BIN: no usable gpg binary" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    if ! "$__bin" --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 --output "$__dest" -- "$__file" > /dev/null; then
        _error "GPG: could not encrypt '$__file' into '$__dest' (passphrase refused or cancelled)" ; __return=1
    fi
    if [ "$__return" == "0" ]; then chmod 600 "$__dest" 2>/dev/null ; fi

    _func_end "$__return" ; return "$__return"
}

# call: _tofu_var_decrypt ($1:var-file) ($2:dest)
# description: Outputs the variable file to hand to `-var-file`: `$1` unchanged when it is a plain `*.tfvars`, or `$2` once an OpenPGP `*.gpg` file has been decrypted into it. Empty in, empty out (no variable file).
# example: `_tofu_var_decrypt "terraform.tfvars.gpg" "/tmp/tofu-varfile.A1b2C3"` — outputs the temporary plaintext path
# return: `0` — the path to use was output on stdout (possibly empty)
# return: `10` (`ERROR_ARGV`) — no usable `gpg` binary for an encrypted file
# return: `1` — the decryption failed
_tofu_var_decrypt () {
    _func_start "$@"

    local __file="${1:-}"
    local __dest="${2:-}"
    local __result=""
    local __return=0

    if _exist "$__file"; then
        if [ "${__file##*.}" == "gpg" ]; then
            _tofu_gpg_decrypt "$__file" "$__dest" || __return=$?
            if [ "$__return" == "0" ]; then __result="$__dest" ; fi
        else
            __result="$__file"
        fi
    fi

    if _exist "$__result"; then echo "$__result" ; fi

    _func_end "$__return" ; return "$__return"
}

# call: _tofu_var_cleanup ($1:path)
# description: Removes the temporary plaintext file created for an encrypted variable file (`no-op` when `$1` is empty), and never touches anything else.
# example: `_tofu_var_cleanup "/tmp/tofu-varfile.A1b2C3"` — removes that file
# return: `0` — the temporary file is gone (or there was none)
_tofu_var_cleanup () {
    _func_start "$@"

    local __path="${1:-}"

    if _exist "$__path"; then rm -f -- "$__path" 2>/dev/null ; fi

    _func_end "0" ; return 0
}

# call: _tofu_run ($@:args)
# description: Runs the resolved `tofu` binary inside the project directory (`-chdir`) and outputs its combined stdout/stderr; this is the only place where the binary is executed, so tests can stub it.
# example: `_tofu_run validate`
# example: `$@` — arguments forwarded verbatim to `tofu`
# return: `0` — the command succeeded
# return: `10` (`ERROR_ARGV`) — no usable binary or project directory
# return: the exit code of the `tofu` command when it failed
_tofu_run () {
    _func_start "$@"

    local __bin
    local __dir
    local __result=""
    local __return=0

    if ! __bin=$(_tofu_bin); then _error "BIN: no usable tofu binary" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! __dir=$(_tofu_dir); then _error "DIR: no usable tofu project directory" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    _verbose "running: $__bin -chdir=$__dir $*"

    if __result=$("$__bin" -chdir="$__dir" "$@" 2>&1); then
        __return=0
    else
        __return=$?
    fi

    if _exist "$__result"; then echo "$__result" ; fi
    if [ "$__return" != "0" ]; then _error "TOFU: the command failed (exit $__return): $*" ; fi

    _func_end "$__return" ; return "$__return"
}

# call: _tofu_confirm ($1:action)
# description: Guards the mutating commands: it succeeds only when the action was explicitly confirmed with `--force` (`FORCE=true`) or `TOFU_CONFIRM=true`.
# example: `_tofu_confirm "apply"` — outputs nothing and returns `0` once `--force` was given
# return: `0` — the action is explicitly confirmed
# return: `10` (`ERROR_ARGV`) — no confirmation for `$1` (or `$1` empty)
_tofu_confirm () {
    _func_start "$@"

    if ! _exist "$1"; then _error "ACTION: no action to confirm" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if [ "${FORCE:-false}" != "true" ] && [ "${TOFU_CONFIRM:-false}" != "true" ]; then _error "ACTION: refusing to run '$1' without --force (or TOFU_CONFIRM=true)" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    _func_end "0" ; return 0
}

# doc-section: Toolchain Commands
# usage: _tofu_version
# description: Prints the OpenTofu version of the resolved binary (`tofu version`).
# example: `my_warp.sh --lib tofu tofu_version`
# return: `0` — version printed
# return: `10` (`ERROR_ARGV`) — no usable binary or project directory
# return: `1` — the `tofu version` command failed.
_tofu_version () {
    _func_start

    local __return=0

    if ! _tofu_run version; then __return=1 ; fi

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_init --backend ($1)
# description: Initializes the working directory (`tofu init`), downloading the providers unless `--backend false` (the default) is passed for an offline `init -backend=false`. Under `--dry-run` the call is only logged.
# example: `my_warp.sh --lib tofu tofu_init`
# example: `my_warp.sh --lib tofu tofu_init --backend true`
# return: `0` — initialization succeeded (or was skipped by `--dry-run`)
# return: `10` (`ERROR_ARGV`) — `--backend` is not `true`/`false`, or no usable binary/directory
# return: `1` — the `tofu init` command failed.
_tofu_init () {
    _func_start "$@"

    local __backend="${1:-false}"
    local __return=0

    if [ "$__backend" != "true" ] && [ "$__backend" != "false" ]; then _error "BACKEND: must be 'true' or 'false' (got '$__backend')" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _tofu_bin > /dev/null; then _error "BIN: no usable tofu binary" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    if [ "${DRY_RUN:-false}" == "true" ]; then
        _info "DRY_RUN: skipping 'tofu init' (backend=$__backend)"
    elif [ "$__backend" == "false" ]; then
        if ! _tofu_run init -backend=false -input=false; then __return=1 ; fi
    else
        if ! _tofu_run init -input=false; then __return=1 ; fi
    fi

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_fmt
# description: Formats the project in place (`tofu fmt -recursive`); under `--dry-run` it only checks the formatting (`-check -diff`) and fails when files need a rewrite.
# example: `my_warp.sh --lib tofu tofu_fmt`
# example: `my_warp.sh --lib tofu --dry-run tofu_fmt` — check mode, never writes
# return: `0` — formatting applied (or already clean in check mode)
# return: `10` (`ERROR_ARGV`) — no usable binary or project directory
# return: `1` — the `tofu fmt` command failed.
_tofu_fmt () {
    _func_start

    local __return=0

    if [ "${DRY_RUN:-false}" == "true" ]; then
        if ! _tofu_run fmt -check -recursive -diff; then __return=1 ; fi
    else
        if ! _tofu_run fmt -recursive; then __return=1 ; fi
    fi

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_validate
# description: Validates the configuration (`tofu validate`) against the already installed providers; when it fails, an actionable hint about `tofu_init` is logged.
# example: `my_warp.sh --lib tofu tofu_validate`
# return: `0` — the configuration is valid
# return: `10` (`ERROR_ARGV`) — no usable binary or project directory
# return: `1` — the `tofu validate` command failed.
_tofu_validate () {
    _func_start

    local __return=0

    if ! _tofu_run validate; then _warning "run 'tofu_init' first when the providers are not installed yet" ; __return=1 ; fi

    _func_end "$__return" ; return "$__return"
}

# doc-section: Lifecycle Commands
# usage: _tofu_plan --var-file ($1) --out ($2)
# description: Shows the execution plan (`tofu plan -input=false`), optionally with a variable file and/or saving the plan to a file (keep it out of git: `*.tfplan` is ignored). An encrypted `terraform.tfvars.gpg` is decrypted on the fly into a temporary file. `--dry-run` never writes the plan file.
# example: `my_warp.sh --lib tofu tofu_plan`
# example: `my_warp.sh --lib tofu tofu_plan --out change.tfplan`
# return: `0` — the plan was produced
# return: `10` (`ERROR_ARGV`) — variable file missing or unusable, or no usable binary/directory
# return: `1` — the `tofu plan` command failed, or the encrypted variable file could not be decrypted.
_tofu_plan () {
    _func_start "$@"

    local __var_file
    local __used_file
    local __tmp
    local __out="${2:-}"
    local __args=()
    local __return=0

    __tmp=$(mktemp "${TMPDIR:-/tmp}/tofu-varfile.XXXXXX" 2>/dev/null)

    if ! __var_file=$(_tofu_var_file "${1:-}"); then _tofu_var_cleanup "$__tmp" ; _error "VAR_FILE: invalid variable file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    __used_file=$(_tofu_var_decrypt "$__var_file" "$__tmp") || __return=$?
    if [ "$__return" != "0" ]; then _tofu_var_cleanup "$__tmp" ; _error "VAR_FILE: could not use the variable file '$__var_file'" ; _func_end "$__return" ; return "$__return" ; fi

    if _exist "$__used_file"; then __args+=("-var-file=$__used_file") ; fi
    if _exist "$__out"; then
        if [ "${DRY_RUN:-false}" == "true" ]; then
            _info "DRY_RUN: not writing the plan file '$__out'"
        else
            __args+=("-out=$__out")
        fi
    fi

    if ! _tofu_run plan -input=false "${__args[@]}"; then __return=1 ; fi

    _tofu_var_cleanup "$__tmp"

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_apply --var-file ($1)
# description: Applies the configuration (`tofu apply -auto-approve`). Requires `--force` (or `TOFU_CONFIRM=true`); under `--dry-run` it only shows the plan. An encrypted `terraform.tfvars.gpg` is decrypted on the fly into a temporary file.
# example: `my_warp.sh --lib tofu --force tofu_apply`
# example: `my_warp.sh --lib tofu --dry-run tofu_apply` — read-only preview
# return: `0` — the apply (or the dry-run plan) succeeded
# return: `10` (`ERROR_ARGV`) — no `--force`, invalid variable file, or no usable binary/directory
# return: `1` — the `tofu apply` command failed, or the encrypted variable file could not be decrypted.
_tofu_apply () {
    _func_start "$@"

    local __var_file
    local __used_file
    local __tmp
    local __args=()
    local __return=0

    if [ "${DRY_RUN:-false}" == "true" ]; then
        _info "DRY_RUN: showing the plan instead of applying it"
    elif ! _tofu_confirm "apply"; then
        _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV"
    fi

    __tmp=$(mktemp "${TMPDIR:-/tmp}/tofu-varfile.XXXXXX" 2>/dev/null)

    if ! __var_file=$(_tofu_var_file "${1:-}"); then _tofu_var_cleanup "$__tmp" ; _error "VAR_FILE: invalid variable file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    __used_file=$(_tofu_var_decrypt "$__var_file" "$__tmp") || __return=$?
    if [ "$__return" != "0" ]; then _tofu_var_cleanup "$__tmp" ; _error "VAR_FILE: could not use the variable file '$__var_file'" ; _func_end "$__return" ; return "$__return" ; fi

    if _exist "$__used_file"; then __args+=("-var-file=$__used_file") ; fi

    if [ "${DRY_RUN:-false}" == "true" ]; then
        if ! _tofu_run plan -input=false "${__args[@]}"; then __return=1 ; fi
    else
        if ! _tofu_run apply -input=false -auto-approve "${__args[@]}"; then __return=1 ; fi
    fi

    _tofu_var_cleanup "$__tmp"

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_destroy --var-file ($1)
# description: Destroys the managed guests (`tofu destroy -auto-approve`). Requires `--force` (or `TOFU_CONFIRM=true`); under `--dry-run` it only shows the destroy plan. An encrypted `terraform.tfvars.gpg` is decrypted on the fly into a temporary file.
# example: `my_warp.sh --lib tofu --force tofu_destroy`
# example: `my_warp.sh --lib tofu --dry-run tofu_destroy` — read-only preview
# return: `0` — the destroy (or the dry-run plan) succeeded
# return: `10` (`ERROR_ARGV`) — no `--force`, invalid variable file, or no usable binary/directory
# return: `1` — the `tofu destroy` command failed, or the encrypted variable file could not be decrypted.
_tofu_destroy () {
    _func_start "$@"

    local __var_file
    local __used_file
    local __tmp
    local __args=()
    local __return=0

    if [ "${DRY_RUN:-false}" == "true" ]; then
        _info "DRY_RUN: showing the destroy plan instead of destroying"
    elif ! _tofu_confirm "destroy"; then
        _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV"
    fi

    __tmp=$(mktemp "${TMPDIR:-/tmp}/tofu-varfile.XXXXXX" 2>/dev/null)

    if ! __var_file=$(_tofu_var_file "${1:-}"); then _tofu_var_cleanup "$__tmp" ; _error "VAR_FILE: invalid variable file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    __used_file=$(_tofu_var_decrypt "$__var_file" "$__tmp") || __return=$?
    if [ "$__return" != "0" ]; then _tofu_var_cleanup "$__tmp" ; _error "VAR_FILE: could not use the variable file '$__var_file'" ; _func_end "$__return" ; return "$__return" ; fi

    if _exist "$__used_file"; then __args+=("-var-file=$__used_file") ; fi

    if [ "${DRY_RUN:-false}" == "true" ]; then
        if ! _tofu_run plan -input=false -destroy "${__args[@]}"; then __return=1 ; fi
    else
        if ! _tofu_run destroy -input=false -auto-approve "${__args[@]}"; then __return=1 ; fi
    fi

    _tofu_var_cleanup "$__tmp"

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_output --name ($1)
# description: Prints the outputs of the state as JSON (`tofu output -json`), either every output or a single one when `--name` is given.
# example: `my_warp.sh --lib tofu tofu_output`
# example: `my_warp.sh --lib tofu tofu_output --name vm_ids`
# return: `0` — outputs printed
# return: `10` (`ERROR_ARGV`) — no usable binary or project directory
# return: `1` — the `tofu output` command failed.
_tofu_output () {
    _func_start "$@"

    local __name="${1:-}"
    local __return=0

    if _exist "$__name"; then
        if ! _tofu_run output -json "$__name"; then __return=1 ; fi
    else
        if ! _tofu_run output -json; then __return=1 ; fi
    fi

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_state_list
# description: Lists the resources recorded in the state (`tofu state list`), one resource address per line.
# example: `my_warp.sh --lib tofu tofu_state_list`
# return: `0` — the state was listed (an empty state is still a success)
# return: `10` (`ERROR_ARGV`) — no usable binary or project directory
# return: `1` — the `tofu state list` command failed.
_tofu_state_list () {
    _func_start

    local __return=0

    if ! _tofu_run state list; then __return=1 ; fi

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_show --file ($1)
# description: Shows the current state, or the plan stored in `--file`, as JSON (`tofu show -json`).
# example: `my_warp.sh --lib tofu tofu_show`
# example: `my_warp.sh --lib tofu tofu_show --file change.tfplan`
# return: `0` — the state/plan was printed
# return: `10` (`ERROR_ARGV`) — `--file` does not exist, or no usable binary/directory
# return: `1` — the `tofu show` command failed.
_tofu_show () {
    _func_start "$@"

    local __file="${1:-}"
    local __return=0

    if _exist "$__file"; then
        if ! _fileexist "$__file"; then _error "FILE: '$__file' not found" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
        if [ -d "$__file" ]; then _error "FILE: '$__file' is a directory, not a file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
        if ! _tofu_run show -json "$__file"; then __return=1 ; fi
    else
        if ! _tofu_run show -json; then __return=1 ; fi
    fi

    _func_end "$__return" ; return "$__return"
}

# doc-section: Project Checks
# usage: _tofu_check
# description: Runs the project quality gate without writing anything: `tofu fmt -check -recursive -diff` first, then `tofu validate` — the first failing step decides the exit code.
# example: `my_warp.sh --lib tofu tofu_check`
# return: `0` — formatting is clean and the configuration validates
# return: `10` (`ERROR_ARGV`) — no usable binary or project directory
# return: `1` — the format check or the validation failed.
_tofu_check () {
    _func_start

    local __return=0

    if ! _tofu_run fmt -check -recursive -diff; then _error "FMT: some files are not formatted" ; __return=1 ; fi
    if [ "$__return" == "0" ]; then
        if ! _tofu_run validate; then _error "VALIDATE: the configuration is invalid" ; __return=1 ; fi
    fi

    _func_end "$__return" ; return "$__return"
}

# usage: _tofu_vars_doc_check
# description: Checks that every `variable "<name>"` of `variables.tf` is documented in `README.md` and in `terraform.tfvars.example` (pure offline check, no `tofu` call).
# example: `my_warp.sh --lib tofu tofu_vars_doc_check`
# return: `0` — every variable is documented in both files
# return: `10` (`ERROR_ARGV`) — project directory, `variables.tf` or `README.md` missing
# return: `1` — at least one variable is undocumented
_tofu_vars_doc_check () {
    _func_start

    local __dir
    local __var
    local __missing=""
    local __return=0

    if ! __dir=$(_tofu_dir); then _error "DIR: no usable tofu project directory" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _fileexist "$__dir/variables.tf"; then _error "FILE: $__dir/variables.tf not found" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _fileexist "$__dir/README.md"; then _error "FILE: $__dir/README.md not found" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    for __var in $($GREP '^variable "' "$__dir/variables.tf" | cut -d '"' -f2); do
        if ! $GREP -q "$__var" "$__dir/README.md"; then __missing="$__missing $__var" ; fi
        if _fileexist "$__dir/terraform.tfvars.example"; then
            if ! $GREP -q "$__var" "$__dir/terraform.tfvars.example"; then __missing="$__missing $__var(tfvars.example)" ; fi
        fi
    done

    if _exist "$__missing"; then _error "DOC: variables not documented in README.md / terraform.tfvars.example:$__missing" ; _func_end "1" ; return 1 ; fi

    _success "every variable of variables.tf is documented"

    _func_end "0" ; return 0
}

# usage: _tofu_vars_encrypt --var-file ($1) --out ($2)
# description: Encrypts a variable file into a passphrase-protected file with GnuPG (`--symmetric`, AES256, passphrase asked on the terminal) -- bootstrap and tests only: the normal way to edit `terraform.tfvars.gpg` is an EasyPG-capable editor.
# example: `my_warp.sh --lib tofu tofu_vars_encrypt` — encrypts terraform.tfvars into terraform.tfvars.gpg
# example: `my_warp.sh --lib tofu tofu_vars_encrypt --var-file lab.tfvars --out lab.tfvars.gpg`
# return: `0` — the file was encrypted (or would be, under `--dry-run`); outputs the encrypted path
# return: `10` (`ERROR_ARGV`) — source file missing, destination already existing without `--force`, or no usable `gpg` binary
# return: `1` — GnuPG failed to encrypt (passphrase refused or cancelled).
_tofu_vars_encrypt () {
    _func_start "$@"

    local __src="${1:-}"
    local __out="${2:-}"
    local __dir
    local __result=""
    local __return=0

    if ! __dir=$(_tofu_dir); then _error "DIR: no usable tofu project directory" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _exist "$__src"; then __src="$__dir/terraform.tfvars" ; elif [ "${__src#/}" == "$__src" ]; then __src="$__dir/$__src" ; fi
    if ! _fileexist "$__src"; then _error "FILE: '$__src' not found" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if [ -d "$__src" ]; then _error "FILE: '$__src' is a directory, not a file" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _exist "$__out"; then __out="$__dir/terraform.tfvars.gpg" ; elif [ "${__out#/}" == "$__out" ]; then __out="$__dir/$__out" ; fi
    if [ -e "$__out" ] && [ "${FORCE:-false}" != "true" ]; then _error "OUT: '$__out' already exists (use --force to overwrite it)" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi
    if ! _tofu_gpg_bin > /dev/null; then _error "BIN: no usable gpg binary" ; _func_end "$ERROR_ARGV" ; return "$ERROR_ARGV" ; fi

    if [ "${DRY_RUN:-false}" == "true" ]; then
        _info "DRY_RUN: not encrypting '$__src' into '$__out'"
        __result="$__out"
    else
        _tofu_gpg_encrypt "$__src" "$__out" || __return=$?
        if [ "$__return" == "0" ]; then __result="$__out" ; fi
    fi

    if _exist "$__result"; then echo "$__result" ; fi

    _func_end "$__return" ; return "$__return"
}

# doc-section: Orchestrator Dispatcher
# call: _usage_tofu ()
# description: Prints the tofu lib help header; the per-command `# usage:` lines themselves are appended by the orchestrator's `_usage`.
# example: `my_warp.sh --lib tofu -h`
# return: Always `0`. Outputs the help header on stdout.
_usage_tofu () {
    _func_start

    echo "tofu - orchestrator wrapper around the OpenTofu CLI"
    echo "  * Project directory : \$TOFU_DIR (default \$MY_GIT_DIR/tofu)"
    echo "  * Binary           : \$TOFU_BIN (default tofu)"
    echo "  * Variable file    : --var-file (\$TOFU_VAR_FILE, then terraform.tfvars.gpg, else terraform.tfvars)"
    echo "  * Encrypted vars   : \${TOFU_VARS_GPG_FILE:-terraform.tfvars.gpg} is decrypted on the fly (GnuPG: \${TOFU_GPG_BIN:-gpg}; passphrase asked on the terminal)"
    echo "  * Read-only mode   : --dry-run (fmt -check, plan instead of apply/destroy)"
    echo "  * tofu_apply/tofu_destroy require --force (or TOFU_CONFIRM=true)"

    _func_end "0" ; return 0
}

# call: _process_lib_tofu ($@:args)
# description: Routes the orchestrator calls to the tofu lib commands, after collecting the `--var-file`, `--out`, `--name`, `--file` and `--backend` options.
# example: `_process_lib_tofu "--var-file 'prod.tfvars' -- tofu_plan --"`
# return: Always `0` when no command was given (usage is printed); otherwise the exit code of the dispatched command.
_process_lib_tofu () {
    _func_start "$@"

    eval "set -- $1"

    local __var_file=""
    local __out=""
    local __name=""
    local __file=""
    local __backend=""
    local __return=0

    while true ; do
        case "$1" in
            --var-file )     __var_file="$2" ; shift ; shift ;;
            --out )          __out="$2"      ; shift ; shift ;;
            --name )         __name="$2"     ; shift ; shift ;;
            --file )         __file="$2"     ; shift ; shift ;;
            --backend )      __backend="$2"  ; shift ; shift ;;
            -- )             break ;;
            * )              shift ;;
        esac
    done

    while true ; do
        case "$1" in
            tofu_version )        _tofu_version                        ; __return=$? ; break ;;
            tofu_init )           _tofu_init "$__backend"              ; __return=$? ; break ;;
            tofu_fmt )            _tofu_fmt                            ; __return=$? ; break ;;
            tofu_validate )       _tofu_validate                       ; __return=$? ; break ;;
            tofu_plan )           _tofu_plan "$__var_file" "$__out"    ; __return=$? ; break ;;
            tofu_apply )          _tofu_apply "$__var_file"            ; __return=$? ; break ;;
            tofu_destroy )        _tofu_destroy "$__var_file"          ; __return=$? ; break ;;
            tofu_output )         _tofu_output "$__name"               ; __return=$? ; break ;;
            tofu_state_list )     _tofu_state_list                     ; __return=$? ; break ;;
            tofu_show )           _tofu_show "$__file"                 ; __return=$? ; break ;;
            tofu_check )          _tofu_check                          ; __return=$? ; break ;;
            tofu_vars_doc_check ) _tofu_vars_doc_check                 ; __return=$? ; break ;;
            tofu_vars_encrypt )   _tofu_vars_encrypt "$__var_file" "$__out" ; __return=$? ; break ;;
            -- )                  shift ;;
            "" )                  _usage ; break ;;
            * )                   _error "command $1 not found" ; _usage ; __return=1 ; break ;;
        esac
    done

    _func_end "$__return" ; return "$__return"
}

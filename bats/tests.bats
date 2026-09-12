#!/usr/bin/env bats

# shellcheck source=/dev/null disable=2001,SC2030,SC2031,SC2317

# global var (DEBUG/VERBOSE are overridable via env: DEBUG=true VERBOSE=true bats ...)
VERBOSE=${VERBOSE:-false}
DEBUG=${DEBUG:-false}

# load the shell runtime and the tofu lib
source "$MY_GIT_DIR/shell/lib_shell.sh"
source "$MY_GIT_DIR/tofu/lib_tofu.sh"

TOFU_PROJECT="$MY_GIT_DIR/tofu"

setup() {
    load '/usr/lib/bats/bats-support/load'
    load '/usr/lib/bats/bats-assert/load'

    # every test works inside its own sandbox: the repository is never written to
    TEST_DIR="$BATS_TEST_TMPDIR/work"
    mkdir -p "$TEST_DIR/bin"

    # a `tofu` stub recording its argv and honouring TOFU_STUB_EXIT / TOFU_STUB_OUT
    cat >"$TEST_DIR/bin/tofu" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TOFU_STUB_LOG"
if [ -n "${TOFU_STUB_OUT:-}" ]; then printf '%s\n' "$TOFU_STUB_OUT" ; fi
exit "${TOFU_STUB_EXIT:-0}"
STUB
    chmod +x "$TEST_DIR/bin/tofu"

    export TOFU_STUB_LOG="$TEST_DIR/tofu.log"
    : >"$TOFU_STUB_LOG"

    export TOFU_BIN="$TEST_DIR/bin/tofu"
    export TOFU_DIR="$TOFU_PROJECT"
    export TOFU_VAR_FILE=""

    unset FORCE DRY_RUN TOFU_CONFIRM
}

teardown() {
    if [ -n "$TEST_DIR" ]; then rm -rf "$TEST_DIR" ; fi
}

# prints what the `tofu` stub received (one invocation per line)
__stub_log() {
    cat "$TOFU_STUB_LOG"
}

# creates an offline harness module (real variables.tf, no provider) and prints its directory
__var_harness() {
    local __h="$TEST_DIR/vars"

    mkdir -p "$__h"
    cp "$TOFU_PROJECT/variables.tf" "$__h/variables.tf"
    cat >"$__h/main.tf" <<'VAREOF'
output "vars" {
  value = {
    images              = var.images
    vm                  = var.vm
    ct                  = var.ct
    pve_endpoint        = var.pve_endpoint
    pve_min_tls         = var.pve_min_tls
    dns_servers         = var.dns_servers
    gateway             = var.gateway
    vm_admin_user       = var.vm_admin_user
    snippet_name_prefix = var.snippet_name_prefix
  }
}

# mirrors the vm_id/ct_id precondition of vms.tf (plan-time and provider-dependent there,
# so it is reproduced here to stay offline)
output "vm_ct_id_space" {
  value = { for k, v in var.vm : k => v.vm_id }

  precondition {
    condition = alltrue([
      for v in values(var.vm) :
      v.vm_id == null || !contains([for c in values(var.ct) : c.ct_id if c.ct_id != null], v.vm_id)
    ])
    error_message = "vm_id is already pinned by a var.ct entry: VMs and containers share the same Proxmox id space."
  }
}
VAREOF
    printf '%s\n' \
        'pve_endpoint = "https://pve.example.com:8006/"' \
        'pve_username = "root@pam"' \
        'pve_node     = "pve"' \
        'vm = {}' \
        'ct = {}' \
        'dns_domain  = "lab.example.com"' \
        'dns_servers = ["10.0.10.1", "10.0.10.2"]' \
        'gateway     = "10.0.10.1"' \
        'ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIreplace-me admin@example.com"]' \
        >"$__h/base.tfvars"
    tofu -chdir="$__h" init -backend=false -input=false >/dev/null 2>&1

    echo "$__h"
}

# runs a variable case through the harness and asserts it is rejected with the expected message
__var_case () {
    local __cap="$1"
    local __msg="$2"
    local __h="$TEST_DIR/vars"

    printf '%s\n' "$__cap" >"$__h/case.tfvars"
    run tofu -chdir="$__h" plan -no-color -input=false -var-file=base.tfvars -var-file=case.tfvars
    assert_failure
    [[ "$output" == *"$__msg"* ]]
}

# rebuild-trigger harness: the real `locals` block of cloud-init.tf + a terraform_data stand-in for the VM
__h2_harness() {
    local __h="$TEST_DIR/h2"

    mkdir -p "$__h/cloud-init"
    cp "$TOFU_PROJECT/variables.tf" "$__h/variables.tf"
    cp "$TOFU_PROJECT/cloud-init/user-config.yaml.tftpl" "$TOFU_PROJECT/cloud-init/vendor-config.yaml" "$__h/cloud-init/"
    awk '/^locals \{/,/^\}$/' "$TOFU_PROJECT/cloud-init.tf" >"$__h/locals.tf"
    cat >"$__h/main.tf" <<'H2EOF'
output "revision" {
  value = local.vm_cloud_init_revision
}

resource "terraform_data" "vm_cloud_init" {
  for_each         = var.vm
  triggers_replace = each.value.vm_recreate_on_cloud_init_change ? local.vm_cloud_init_revision : "disabled"
}

resource "terraform_data" "guest" {
  for_each = var.vm
  input    = each.key

  lifecycle {
    replace_triggered_by = [terraform_data.vm_cloud_init[each.key]]
  }
}
H2EOF
    printf '%s\n' \
        'pve_endpoint = "https://pve.example.com:8006/"' \
        'pve_username = "root@pam"' \
        'pve_node     = "pve"' \
        'ct = {}' \
        'dns_domain  = "lab.example.com"' \
        'dns_servers = ["10.0.10.1"]' \
        'gateway     = "10.0.10.1"' \
        >"$__h/base.tfvars"
    printf '%s\n' \
        'ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkey-one admin@example.com"]' \
        'vm = { web = { vm_name = "web", vm_ip = "10.0.10.11/24", vm_datastore_storage_location = "local-lvm" } }' \
        >"$__h/off.tfvars"
    printf '%s\n' \
        'ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkey-TWO admin@example.com"]' \
        'vm = { web = { vm_name = "web", vm_ip = "10.0.10.11/24", vm_datastore_storage_location = "local-lvm" } }' \
        >"$__h/off_keys2.tfvars"
    printf '%s\n' \
        'ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkey-one admin@example.com"]' \
        'vm = { web = { vm_name = "web", vm_ip = "10.0.10.11/24", vm_datastore_storage_location = "local-lvm", vm_recreate_on_cloud_init_change = true } }' \
        >"$__h/on.tfvars"
    printf '%s\n' \
        'ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIkey-TWO admin@example.com"]' \
        'vm = { web = { vm_name = "web", vm_ip = "10.0.10.11/24", vm_datastore_storage_location = "local-lvm", vm_recreate_on_cloud_init_change = true } }' \
        >"$__h/on_keys2.tfvars"
    tofu -chdir="$__h" init -backend=false -input=false >/dev/null 2>&1

    echo "$__h"
}

# skips the test when the real OpenTofu binary is unavailable
__require_tofu() {
    if ! command -v tofu >/dev/null 2>&1; then
        skip "the tofu binary is not installed"
    fi
    export TOFU_BIN
    TOFU_BIN="$(command -v tofu)"
}

# ------------------------------------------------------- A. runtime helpers --
@test "_tofu_bin => returns the configured binary" {
    run _tofu_bin
    assert_success
    assert_output "$TOFU_BIN"
}

@test "_tofu_bin => fails when the binary is missing" {
    export TOFU_BIN="$TEST_DIR/nope/tofu"
    run _tofu_bin
    assert_failure
    [[ "$output" == *"no usable"* ]]
}

@test "_tofu_bin => falls back to 'tofu' when TOFU_BIN is empty" {
    export TOFU_BIN=""
    export PATH="$TEST_DIR/bin:$PATH"
    run _tofu_bin
    assert_success
    assert_output "tofu"
}

@test "_tofu_dir => returns the project directory" {
    run _tofu_dir
    assert_success
    assert_output "$TOFU_PROJECT"
}

@test "_tofu_dir => fails on a missing directory" {
    export TOFU_DIR="$TEST_DIR/missing"
    run _tofu_dir
    assert_failure
    [[ "$output" == *"does not exist"* ]]
}

@test "_tofu_dir => fails when no .tf file is present" {
    mkdir -p "$TEST_DIR/notf"
    printf 'nothing to see\n' >"$TEST_DIR/notf/README.md"
    export TOFU_DIR="$TEST_DIR/notf"
    run _tofu_dir
    assert_failure
    [[ "$output" == *"no .tf file"* ]]
}

@test "_tofu_var_file => returns an existing file as an absolute path" {
    printf 'pve_node = "pve"\n' >"$TEST_DIR/prod.tfvars"
    run _tofu_var_file "$TEST_DIR/prod.tfvars"
    assert_success
    assert_output "$(realpath -- "$TEST_DIR/prod.tfvars")"
}

@test "_tofu_var_file => resolves a relative file inside the project directory" {
    mkdir -p "$TEST_DIR/project"
    printf 'variable "x" { type = string }\n' >"$TEST_DIR/project/variables.tf"
    printf 'x = "1"\n' >"$TEST_DIR/project/lab.tfvars"
    export TOFU_DIR="$TEST_DIR/project"
    run _tofu_var_file "lab.tfvars"
    assert_success
    assert_output "$(realpath -- "$TEST_DIR/project/lab.tfvars")"
}

@test "_tofu_var_file => rejects a directory" {
    mkdir -p "$TEST_DIR/notafile"
    run _tofu_var_file "$TEST_DIR/notafile"
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
    [[ "$output" == *"is a directory"* ]]
}

@test "_tofu_var_file => fails on a missing file" {
    run _tofu_var_file "$TEST_DIR/missing.tfvars"
    assert_failure
    [[ "$output" == *"not found"* ]]
}

@test "_tofu_var_file => falls back to terraform.tfvars when present" {
    mkdir -p "$TEST_DIR/project"
    printf 'variable "x" {}\n' >"$TEST_DIR/project/variables.tf"
    printf 'x = "1"\n' >"$TEST_DIR/project/terraform.tfvars"
    export TOFU_DIR="$TEST_DIR/project"
    run _tofu_var_file
    assert_success
    assert_output "$(realpath -- "$TEST_DIR/project/terraform.tfvars")"
}

@test "_tofu_var_file => returns nothing when no var file is configured" {
    mkdir -p "$TEST_DIR/noconf"
    printf 'variable "x" {}\n' >"$TEST_DIR/noconf/variables.tf"
    export TOFU_DIR="$TEST_DIR/noconf"
    run _tofu_var_file
    assert_success
    assert_output ""
}

@test "_tofu_var_file => uses TOFU_VAR_FILE when no argument is given" {
    printf 'pve_node = "pve"\n' >"$TEST_DIR/conf.tfvars"
    export TOFU_VAR_FILE="$TEST_DIR/conf.tfvars"
    run _tofu_var_file
    assert_success
    assert_output "$(realpath -- "$TEST_DIR/conf.tfvars")"
}

@test "_tofu_run => forwards the chdir and the arguments" {
    run _tofu_run validate
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT validate"
}

@test "_tofu_run => prints the binary output" {
    export TOFU_STUB_OUT="all good"
    run _tofu_run plan
    assert_success
    assert_output "all good"
}

@test "_tofu_run => propagates the exit code of the binary" {
    export TOFU_STUB_EXIT=7
    run _tofu_run plan
    [ "$status" -eq 7 ]
    [[ "$output" == *"exit 7"* ]]
}

@test "_tofu_run => fails when the binary is unusable" {
    export TOFU_BIN="$TEST_DIR/nope/tofu"
    run _tofu_run validate
    assert_failure
    [[ "$output" == *"no usable tofu binary"* ]]
}

@test "_tofu_confirm => succeeds with FORCE=true" {
    export FORCE=true
    run _tofu_confirm "apply"
    assert_success
}

@test "_tofu_confirm => succeeds with TOFU_CONFIRM=true" {
    export TOFU_CONFIRM=true
    run _tofu_confirm "destroy"
    assert_success
}

@test "_tofu_confirm => refuses without an explicit confirmation" {
    run _tofu_confirm "apply"
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
    [[ "$output" == *"without --force"* ]]
}

@test "_tofu_confirm => refuses an empty action" {
    run _tofu_confirm ""
    assert_failure
    [[ "$output" == *"no action to confirm"* ]]
}

@test "lib_tofu.sh conf => the environment wins over conf/tofu.conf" {
    mkdir -p "$TEST_DIR/fakeroot/tofu/conf"
    printf 'TOFU_BIN=/from/conf\nTOFU_DIR=/from/conf\n' >"$TEST_DIR/fakeroot/tofu/conf/tofu.conf"
    run env MY_GIT_DIR="$TEST_DIR/fakeroot" TOFU_BIN=/from/env TOFU_DIR=/from/env bash -c "source '$TOFU_PROJECT/lib_tofu.sh'; echo \"\$TOFU_BIN \$TOFU_DIR\""
    assert_success
    assert_output "/from/env /from/env"
}

@test "lib_tofu.sh conf => conf/tofu.conf fills the empty values" {
    mkdir -p "$TEST_DIR/fakeroot2/tofu/conf"
    printf 'TOFU_BIN=/from/conf\nTOFU_DIR=/from/conf\n' >"$TEST_DIR/fakeroot2/tofu/conf/tofu.conf"
    run env -u TOFU_BIN -u TOFU_DIR MY_GIT_DIR="$TEST_DIR/fakeroot2" bash -c "source '$TOFU_PROJECT/lib_tofu.sh'; echo \"\$TOFU_BIN \$TOFU_DIR\""
    assert_success
    assert_output "/from/conf /from/conf"
}

@test "lib_tofu.sh conf => no conf file leaves the defaults empty" {
    mkdir -p "$TEST_DIR/fakeroot3/tofu"
    run env -u TOFU_BIN -u TOFU_DIR MY_GIT_DIR="$TEST_DIR/fakeroot3" bash -c "source '$TOFU_PROJECT/lib_tofu.sh'; echo \"[\${TOFU_BIN:-}][\${TOFU_DIR:-}]\""
    assert_success
    assert_output "[][]"
}

# --------------------------------------------------------- B. commands -------
@test "_tofu_version => runs 'tofu version'" {
    run _tofu_version
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT version"
}

@test "_tofu_init => defaults to an offline init (backend=false)" {
    run _tofu_init
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT init -backend=false -input=false"
}

@test "_tofu_init => --backend true runs a full init" {
    run _tofu_init "true"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT init -input=false"
}

@test "_tofu_init => rejects an invalid --backend value" {
    run _tofu_init "maybe"
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
    [[ "$output" == *"BACKEND"* ]]
    run __stub_log
    assert_output ""
}

@test "_tofu_init => DRY_RUN skips the init" {
    export DRY_RUN=true
    run _tofu_init
    assert_success
    run __stub_log
    assert_output ""
}

@test "_tofu_fmt => formats recursively" {
    run _tofu_fmt
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT fmt -recursive"
}

@test "_tofu_fmt => DRY_RUN only checks the formatting" {
    export DRY_RUN=true
    run _tofu_fmt
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT fmt -check -recursive -diff"
}

@test "_tofu_validate => runs 'tofu validate'" {
    run _tofu_validate
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT validate"
}

@test "_tofu_validate => hints at tofu_init when validate fails" {
    export TOFU_STUB_EXIT=1
    run _tofu_validate
    assert_failure
    [[ "$output" == *"tofu_init"* ]]
}

@test "_tofu_plan => runs a plan" {
    run _tofu_plan
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false"
}

@test "_tofu_plan => passes the variable file" {
    printf 'pve_node = "pve"\n' >"$TEST_DIR/prod.tfvars"
    run _tofu_plan "$TEST_DIR/prod.tfvars"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false -var-file=$(realpath -- "$TEST_DIR/prod.tfvars")"
}

@test "_tofu_plan => saves the plan with --out" {
    run _tofu_plan "" "change.tfplan"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false -out=change.tfplan"
}

@test "_tofu_plan => DRY_RUN ignores --out and writes nothing" {
    export DRY_RUN=true
    run _tofu_plan "" "change.tfplan"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false"
    [ ! -e "$TOFU_PROJECT/change.tfplan" ]
}

@test "_tofu_plan => fails on a missing variable file" {
    run _tofu_plan "$TEST_DIR/missing.tfvars"
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
    run __stub_log
    assert_output ""
}

@test "_tofu_apply => refuses to run without --force" {
    run _tofu_apply
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
    [[ "$output" == *"without --force"* ]]
    run __stub_log
    assert_output ""
}

@test "_tofu_apply => applies with --force" {
    export FORCE=true
    run _tofu_apply
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT apply -input=false -auto-approve"
}

@test "_tofu_apply => --dry-run only shows the plan" {
    export DRY_RUN=true
    run _tofu_apply
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false"
}

@test "_tofu_apply => forwards the variable file when forced" {
    export FORCE=true
    printf 'pve_node = "pve"\n' >"$TEST_DIR/prod.tfvars"
    run _tofu_apply "$TEST_DIR/prod.tfvars"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT apply -input=false -auto-approve -var-file=$(realpath -- "$TEST_DIR/prod.tfvars")"
}

@test "_tofu_destroy => refuses to run without --force" {
    run _tofu_destroy
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
    run __stub_log
    assert_output ""
}

@test "_tofu_destroy => destroys with --force" {
    export FORCE=true
    run _tofu_destroy
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT destroy -input=false -auto-approve"
}

@test "_tofu_destroy => --dry-run only shows the destroy plan" {
    export DRY_RUN=true
    run _tofu_destroy
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false -destroy"
}

@test "_tofu_output => prints every output as json" {
    run _tofu_output
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT output -json"
}

@test "_tofu_output => selects a single output with --name" {
    run _tofu_output "vm_ids"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT output -json vm_ids"
}

@test "_tofu_state_list => lists the state" {
    run _tofu_state_list
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT state list"
}

@test "_tofu_show => shows the current state as json" {
    run _tofu_show
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT show -json"
}

@test "_tofu_show => shows the plan given with --file" {
    printf '{}\n' >"$TEST_DIR/change.tfplan"
    run _tofu_show "$TEST_DIR/change.tfplan"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT show -json $TEST_DIR/change.tfplan"
}

@test "_tofu_show => fails on a missing --file" {
    run _tofu_show "$TEST_DIR/missing.tfplan"
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
}

# ----------------------------------------------------------- C. checks -------
@test "_tofu_check => runs the format check then validate" {
    run _tofu_check
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT fmt -check -recursive -diff
-chdir=$TOFU_PROJECT validate"
}

@test "_tofu_check => stops before validate when the formatting differs" {
    export TOFU_STUB_EXIT=3
    run _tofu_check
    assert_failure
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT fmt -check -recursive -diff"
}

@test "_tofu_vars_doc_check => passes on the project" {
    run _tofu_vars_doc_check
    assert_success
    [[ "$output" == *"every variable"* ]]
}

@test "_tofu_vars_doc_check => detects an undocumented variable" {
    mkdir -p "$TEST_DIR/docs"
    printf 'variable "documented" { type = string }\nvariable "forgotten" { type = string }\n' >"$TEST_DIR/docs/variables.tf"
    printf 'variables: documented\n' >"$TEST_DIR/docs/README.md"
    printf 'documented = "1"\n' >"$TEST_DIR/docs/terraform.tfvars.example"
    export TOFU_DIR="$TEST_DIR/docs"
    run _tofu_vars_doc_check
    assert_failure
    [[ "$output" == *"forgotten"* ]]
}

@test "_tofu_vars_doc_check => fails when README.md is missing" {
    mkdir -p "$TEST_DIR/noreadme"
    printf 'variable "x" { type = string }\n' >"$TEST_DIR/noreadme/variables.tf"
    export TOFU_DIR="$TEST_DIR/noreadme"
    run _tofu_vars_doc_check
    assert_failure
    [[ "$output" == *"README.md not found"* ]]
}

# ------------------------------------------------- D. orchestrator/CLI ------
@test "_process_lib_tofu => dispatches tofu_version" {
    run _process_lib_tofu "-- 'tofu_version' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT version"
}

@test "_process_lib_tofu => forwards --var-file to tofu_plan" {
    printf 'pve_node = "pve"\n' >"$TEST_DIR/prod.tfvars"
    run _process_lib_tofu "--var-file '$TEST_DIR/prod.tfvars' -- 'tofu_plan' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false -var-file=$(realpath -- "$TEST_DIR/prod.tfvars")"
}

@test "_process_lib_tofu => forwards --out to tofu_plan" {
    run _process_lib_tofu "--out 'change.tfplan' -- 'tofu_plan' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT plan -input=false -out=change.tfplan"
}

@test "_process_lib_tofu => forwards --name to tofu_output" {
    run _process_lib_tofu "--name 'vm_ids' -- 'tofu_output' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT output -json vm_ids"
}

@test "_process_lib_tofu => forwards --backend to tofu_init" {
    run _process_lib_tofu "--backend 'true' -- 'tofu_init' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT init -input=false"
}

@test "_process_lib_tofu => forwards --file to tofu_show" {
    printf '{}\n' >"$TEST_DIR/change.tfplan"
    run _process_lib_tofu "--file '$TEST_DIR/change.tfplan' -- 'tofu_show' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT show -json $TEST_DIR/change.tfplan"
}

@test "_process_lib_tofu => dispatches tofu_fmt" {
    run _process_lib_tofu "-- 'tofu_fmt' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT fmt -recursive"
}

@test "_process_lib_tofu => dispatches tofu_validate" {
    run _process_lib_tofu "-- 'tofu_validate' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT validate"
}

@test "_process_lib_tofu => refuses tofu_apply without --force (binary never runs)" {
    run _process_lib_tofu "-- 'tofu_apply' --"
    assert_failure
    [ "$status" -eq "$ERROR_ARGV" ]
    run __stub_log
    assert_output ""
}

@test "_process_lib_tofu => dispatches tofu_destroy with --force" {
    export FORCE=true
    run _process_lib_tofu "-- 'tofu_destroy' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT destroy -input=false -auto-approve"
}

@test "_process_lib_tofu => dispatches tofu_state_list" {
    run _process_lib_tofu "-- 'tofu_state_list' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT state list"
}

@test "_process_lib_tofu => dispatches tofu_check" {
    run _process_lib_tofu "-- 'tofu_check' --"
    assert_success
    run __stub_log
    assert_output "-chdir=$TOFU_PROJECT fmt -check -recursive -diff
-chdir=$TOFU_PROJECT validate"
}

@test "_process_lib_tofu => an unknown command prints the usage" {
    export LIB="tofu"
    run _process_lib_tofu "-- 'bogus_command' --"
    assert_failure
    [[ "$output" == *"command bogus_command not found"* ]]
    [[ "$output" == *"tofu_version"* ]]
}

@test "_process_lib_tofu => no command prints the usage" {
    export LIB="tofu"
    run _process_lib_tofu "-- --"
    assert_success
    [[ "$output" == *"orchestrator wrapper"* ]]
}

@test "_usage_tofu => prints the help header" {
    run _usage_tofu
    assert_success
    [[ "$output" == *"tofu - orchestrator wrapper"* ]]
    [[ "$output" == *"--force"* ]]
}

@test "CLI => my_warp.sh --list-libs discovers the tofu lib" {
    run "$MY_GIT_DIR/shell/my_warp.sh" --list-libs
    assert_success
    [[ "$output" == *tofu* ]]
}

@test "CLI => my_warp.sh --lib tofu -h lists the commands" {
    run "$MY_GIT_DIR/shell/my_warp.sh" --lib tofu -h
    assert_success
    [[ "$output" == *"my_warp.sh --lib tofu tofu_check"* ]]
    [[ "$output" == *"my_warp.sh --lib tofu tofu_apply"* ]]
}

@test "CLI => my_warp.sh --lib tofu tofu_vars_doc_check passes on the project" {
    run "$MY_GIT_DIR/shell/my_warp.sh" --lib tofu tofu_vars_doc_check
    assert_success
}

# ------------------------------------- E. project invariants (real tofu) -----
@test "project => tofu fmt -check is clean" {
    __require_tofu
    export DRY_RUN=true
    run _tofu_fmt
    assert_success
}

@test "project => tofu validate is clean" {
    __require_tofu
    if [ ! -d "$TOFU_PROJECT/.terraform" ]; then
        skip "the project is not initialized (.terraform missing)"
    fi
    run _tofu_validate
    assert_success
}

@test "project => tofu_check passes on the project" {
    __require_tofu
    if [ ! -d "$TOFU_PROJECT/.terraform" ]; then
        skip "the project is not initialized (.terraform missing)"
    fi
    run _tofu_check
    assert_success
}

@test "project => pve_endpoint rejects plain http" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'pve_endpoint = "http://pve.example.com:8006/"' "pve_endpoint must be an HTTPS URL"
}

@test "project => pve_endpoint rejects a host with a space" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'pve_endpoint = "https://a b"' "pve_endpoint must be an HTTPS URL"
}

@test "project => pve_endpoint rejects a path suffix" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'pve_endpoint = "https://pve.example.com:8006/api2/json"' "pve_endpoint must be an HTTPS URL"
}

@test "project => pve_endpoint rejects an out-of-range port" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'pve_endpoint = "https://pve.example.com:99999"' "between 1 and 65535"
}

@test "project => pve_endpoint accepts a valid endpoint" {
    __require_tofu
    __var_harness >/dev/null
    local __h="$TEST_DIR/vars"
    printf '%s\n' 'pve_endpoint = "https://pve:8006/"' >"$__h/case.tfvars"
    run tofu -chdir="$__h" plan -no-color -input=false -var-file=base.tfvars -var-file=case.tfvars
    assert_success
}

@test "project => dns_servers rejects an IPv6 resolver" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'dns_servers = ["10.0.10.1", "fe80::1"]' "Every dns_servers entry must be a valid IPv4 address"
}

@test "project => gateway rejects an IPv6 address" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'gateway = "fe80::1"' "gateway must be a valid IPv4 address"
}

@test "project => images reject a qcow2 file_name" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'images = { x = { content_type = "iso", url = "https://cloud.example.com/a.qcow2", file_name = "a.qcow2" } }' "must end with .img or .iso"
}

@test "project => images require file_name" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'images = { x = { content_type = "iso", url = "https://cloud.example.com/a.img" } }' "file_name"
}

@test "project => images reject a checksum of the wrong length" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'images = { x = { content_type = "iso", url = "https://cloud.example.com/a.img", file_name = "a.img", checksum = "abc123" } }' "checksum must be a hexadecimal digest"
}

@test "project => vm_id below 100 is rejected" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'vm = { web = { vm_name = "web", vm_ip = "10.0.10.11/24", vm_datastore_storage_location = "local-lvm", vm_id = 5 } }' "must be at least 100"
}

@test "project => a duplicate vm_id is rejected" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'vm = { web = { vm_name = "web", vm_ip = "10.0.10.11/24", vm_datastore_storage_location = "local-lvm", vm_id = 101 }, db = { vm_name = "db", vm_ip = "10.0.10.12/24", vm_datastore_storage_location = "local-lvm", vm_id = 101 } }' "vm_id must be unique"
}

@test "project => vm_admin_user rejects an invalid user name" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'vm_admin_user = "Admin User"' "must be a valid UNIX user name"
}

@test "project => pve_min_tls rejects an unknown version" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'pve_min_tls = "1.1.1"' "pve_min_tls must be one of"
}

@test "project => snippet_name_prefix rejects an invalid prefix" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'snippet_name_prefix = "-tofu"' "snippet_name_prefix must start with"
}

@test "project => the harness accepts a fully valid set of values" {
    __require_tofu
    __var_harness >/dev/null
    local __h="$TEST_DIR/vars"
    : >"$__h/case.tfvars"
    run tofu -chdir="$__h" plan -no-color -input=false -var-file=base.tfvars -var-file=case.tfvars
    assert_success
}

@test "project => a vm_id colliding with a ct_id is rejected" {
    __require_tofu
    __var_harness >/dev/null
    __var_case 'vm = { web = { vm_name = "web", vm_ip = "10.0.10.11/24", vm_datastore_storage_location = "local-lvm", vm_id = 121 } }
ct = { dns = { ct_name = "dns", ct_ip = "10.0.10.21/24", ct_datastore_storage_location = "local-lvm", ct_id = 121 } }' "already pinned by a var.ct entry"
}

@test "project => H2 rebuild flag: opting out never rebuilds the guest" {
    __require_tofu
    __h2_harness >/dev/null
    run tofu -chdir="$TEST_DIR/h2" apply -auto-approve -no-color -input=false -var-file=base.tfvars -var-file=off.tfvars
    assert_success
    run tofu -chdir="$TEST_DIR/h2" plan -no-color -input=false -var-file=base.tfvars -var-file=off_keys2.tfvars
    assert_success
    [[ "$output" != *"must be replaced"* ]]
}

@test "project => H2 rebuild flag: opting in rebuilds the guest on a change" {
    __require_tofu
    __h2_harness >/dev/null
    run tofu -chdir="$TEST_DIR/h2" apply -auto-approve -no-color -input=false -var-file=base.tfvars -var-file=on.tfvars
    assert_success
    run tofu -chdir="$TEST_DIR/h2" plan -no-color -input=false -var-file=base.tfvars -var-file=on_keys2.tfvars
    assert_success
    [[ "$output" == *"must be replaced"* ]]
}

@test "project => H2 rebuild flag: editing the template rebuilds the guest" {
    __require_tofu
    __h2_harness >/dev/null
    run tofu -chdir="$TEST_DIR/h2" apply -auto-approve -no-color -input=false -var-file=base.tfvars -var-file=on_keys2.tfvars
    assert_success
    printf '\n# template tweak\n' >>"$TEST_DIR/h2/cloud-init/vendor-config.yaml"
    run tofu -chdir="$TEST_DIR/h2" plan -no-color -input=false -var-file=base.tfvars -var-file=on_keys2.tfvars
    assert_success
    [[ "$output" == *"must be replaced"* ]]
}

@test "project => functions.md is in sync with the lib markers" {
    export LIB="tofu"
    local __out="$BATS_TEST_TMPDIR/functions.generated.md"
    run _doc "$__out"
    assert_success
    run diff "$TOFU_PROJECT/functions.md" "$__out"
    assert_success
}

@test "project => every variable of variables.tf is documented in README.md" {
    local __vars
    local __v
    __vars=$(grep '^variable "' "$TOFU_PROJECT/variables.tf" | cut -d '"' -f2)
    if [ -z "$__vars" ]; then
        fail "no variable found in variables.tf"
    fi
    for __v in $__vars; do
        if ! grep -q "$__v" "$TOFU_PROJECT/README.md"; then
            fail "the variable $__v is not documented in README.md"
        fi
    done
}

@test "project => every variable of variables.tf appears in terraform.tfvars.example" {
    local __vars
    local __v
    __vars=$(grep '^variable "' "$TOFU_PROJECT/variables.tf" | cut -d '"' -f2)
    if [ -z "$__vars" ]; then
        fail "no variable found in variables.tf"
    fi
    for __v in $__vars; do
        if ! grep -q "$__v" "$TOFU_PROJECT/terraform.tfvars.example"; then
            fail "the variable $__v is missing from terraform.tfvars.example"
        fi
    done
}

@test "project => .gitignore keeps state, variables and plan files out of git" {
    run git -C "$TOFU_PROJECT" check-ignore -q terraform.tfvars
    assert_success
    run git -C "$TOFU_PROJECT" check-ignore -q terraform.tfstate
    assert_success
    run git -C "$TOFU_PROJECT" check-ignore -q change.tfplan
    assert_success
    run git -C "$TOFU_PROJECT" check-ignore -q plan.out
    assert_success
}

@test "project => .terraform.lock.hcl is present and not ignored" {
    [ -f "$TOFU_PROJECT/.terraform.lock.hcl" ]
    run git -C "$TOFU_PROJECT" check-ignore -q .terraform.lock.hcl
    assert_failure
}

@test "project => the provider constraint is consistent between providers.tf and README.md" {
    run grep -q '~> 0.74.0' "$TOFU_PROJECT/providers.tf"
    assert_success
    run grep -q '~> 0.74.0' "$TOFU_PROJECT/README.md"
    assert_success
}

@test "project => the provider negotiates the TLS version from the variable" {
    run grep -q 'min_tls = var.pve_min_tls' "$TOFU_PROJECT/providers.tf"
    assert_success
}

@test "project => the provider reads the SSH key file itself" {
    run grep -q 'file(var.pve_ssh_private_key_file)' "$TOFU_PROJECT/providers.tf"
    assert_success
}

@test "project => no variable file calls a function" {
    # A *.tfvars file accepts literals only: a function call there (file(), ...) makes
    # every plan fail with "Function calls not allowed". The call belongs to a *.tf file.
    run grep -E '=[[:space:]]*[a-z_]+[(]' "$TOFU_PROJECT/terraform.tfvars.example"
    assert_failure
}

@test "project => the cloud-init snippets are namespaced with the prefix variable" {
    run grep -q 'snippet_name_prefix}-user-config.yaml' "$TOFU_PROJECT/cloud-init.tf"
    assert_success
    run grep -q 'snippet_name_prefix}-vendor-config.yaml' "$TOFU_PROJECT/cloud-init.tf"
    assert_success
}

@test "project => the VM admin user comes from the variable, not a literal" {
    run grep -q 'admin_user      = var.vm_admin_user' "$TOFU_PROJECT/cloud-init.tf"
    assert_success
    run grep -q 'admin_user      = "debian"' "$TOFU_PROJECT/cloud-init.tf"
    assert_failure
}

@test "project => the cloud-init revision hashes the rendered payload" {
    run grep -q 'sha256(jsonencode(\[local.vm_user_data, local.vm_vendor_data\]))' "$TOFU_PROJECT/cloud-init.tf"
    assert_success
}

@test "project => README documents the first-boot-only behaviour and the rebuild flag" {
    run grep -q 'first boot' "$TOFU_PROJECT/README.md"
    assert_success
    run grep -q 'vm_recreate_on_cloud_init_change' "$TOFU_PROJECT/README.md"
    assert_success
}

@test "project => README warns that the LXC templates are not verified" {
    run grep -q 'unverified' "$TOFU_PROJECT/README.md"
    assert_success
}

@test "project => the apply and destroy guard is documented in the README" {
    run grep -q 'tofu_apply' "$TOFU_PROJECT/README.md"
    assert_success
    run grep -q '\-\-force' "$TOFU_PROJECT/README.md"
    assert_success
}

#!/bin/bash
# Unified OpenTofu Management Script (AWS SSO + var-file aware, with logging)
# Usage: ./tofu-manage-coder.sh

set -o pipefail   # so `cmd | tee` reports cmd's failure, not tee's

# ---------- Config ----------
LOG_DIR="logs"
STATE_FILE=".tofu-manage.env"     # remembers last var-file / profile / plan
mkdir -p "$LOG_DIR"
export AWS_PAGER=""               # never open a pager for aws CLI output (same as --no-cli-pager)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

VAR_FILE=""
AWS_PROFILE_NAME=""
LAST_PLAN=""
PARALLELISM=10     # tofu default is 10
REFRESH="true"     # "false" adds -refresh=false to plan/destroy
TARGET_ARGS=()     # filled by options 9/10 only; empty for every other action
MODE_ARGS=()       # (-destroy) for option 10 only

# ---------- Persisted settings ----------
load_state() { [ -f "$STATE_FILE" ] && source "$STATE_FILE"; }
save_state() {
    cat > "$STATE_FILE" <<EOF
VAR_FILE="$VAR_FILE"
AWS_PROFILE_NAME="$AWS_PROFILE_NAME"
LAST_PLAN="$LAST_PLAN"
PARALLELISM="$PARALLELISM"
REFRESH="$REFRESH"
EOF
}

# ---------- Prompts ----------
prompt_settings() {
    local input
    echo ""
    read -e -i "$VAR_FILE" -p "Vars file (tab completes) [${VAR_FILE:-vars/example.tfvars}]: " input
    VAR_FILE="${input:-${VAR_FILE:-vars/example.tfvars}}"
    if [ ! -f "$VAR_FILE" ]; then
        print_error "Vars file not found: $VAR_FILE"
        VAR_FILE=""
        return 1
    fi

    read -e -i "$AWS_PROFILE_NAME" -p "AWS profile name [${AWS_PROFILE_NAME:-coder-demo}]: " input
    AWS_PROFILE_NAME="${input:-${AWS_PROFILE_NAME:-coder-demo}}"

    save_state
    print_success "Using vars: $VAR_FILE | profile: $AWS_PROFILE_NAME"
}

ensure_settings() {
    if [ -z "$VAR_FILE" ] || [ -z "$AWS_PROFILE_NAME" ]; then
        prompt_settings || return 1
    fi
}

# ---------- AWS SSO ----------
sso_login() {
    export AWS_PROFILE="$AWS_PROFILE_NAME"
    if aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" &>/dev/null; then
        print_success "AWS SSO session for '$AWS_PROFILE_NAME' is still valid"
        return 0
    fi
    print_info "Logging in via AWS SSO device code (profile: $AWS_PROFILE_NAME)..."
    print_info "Open the URL shown in your own browser, enter the code and approve."
    aws sso login --profile "$AWS_PROFILE_NAME" --use-device-code || { print_error "SSO login failed"; return 1; }
    aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" &>/dev/null \
        && print_success "SSO login successful" \
        || { print_error "SSO login did not produce a valid session"; return 1; }
}

# Common tofu args
build_args() {
    VAR_ARGS=(--var-file="$VAR_FILE" --var="aws_profile=$AWS_PROFILE_NAME")
    TUNE_ARGS=(-parallelism="$PARALLELISM")
    [ "$REFRESH" = "false" ] && TUNE_ARGS+=(-refresh=false)
}

prompt_targets() {
    TARGET_ARGS=()
    local input t
    echo ""
    echo "Enter target(s), space or comma separated (e.g. module.coder aws_instance.web)."
    echo "Type '?' to list resources currently in state, or leave blank to cancel."
    while true; do
        read -e -p "Target(s): " input
        if [ "$input" = "?" ]; then
            tofu state list 2>/dev/null | less -FRX
            continue
        fi
        break
    done
    for t in ${input//,/ }; do
        TARGET_ARGS+=(-target="$t")
    done
    if [ ${#TARGET_ARGS[@]} -eq 0 ]; then
        print_warning "No targets entered - cancelled"
        return 1
    fi
    print_info "Targets: ${TARGET_ARGS[*]}"
}

prompt_tuning() {
    local input
    read -p "Parallelism [${PARALLELISM}] (tofu default 10): " input
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ]; then PARALLELISM="$input"
    elif [ -n "$input" ]; then print_warning "Not a number, keeping $PARALLELISM"; fi

    read -p "Refresh state before plan/destroy? [Y/n] (currently: $REFRESH): " input
    case "$input" in
        [Nn]*) REFRESH="false" ;;
        [Yy]*) REFRESH="true" ;;
    esac
    save_state
    print_success "Parallelism: $PARALLELISM | refresh: $REFRESH"
    [ "$REFRESH" = "false" ] && print_warning "Refresh off: drift made outside tofu will NOT be detected in the plan"
}

# Run a command, show it live, and keep a log (ANSI colours stripped in the log)
run_logged() {
    local label="$1"; shift
    local log="$LOG_DIR/${label}-$(date +%F_%H%M%S).log"
    print_info "Logging to $log"
    "$@" 2>&1 | tee >(sed -u 's/\x1b\[[0-9;]*[mK]//g' > "$log")
    local rc=${PIPESTATUS[0]}
    sleep 0.2   # let the log writer flush
    return $rc
}

# ---------- Tofu actions ----------
initialize_tofu() {
    print_info "Initializing OpenTofu..."
    if tofu init; then print_success "Initialization successful"
    else print_error "Initialization failed"; return 1; fi
}

create_plan() {
    local default_name="tofu-$(date +%Y%m%d-%H%M).out" name
    [ ${#TARGET_ARGS[@]} -gt 0 ] && default_name="tofu-targeted-$(date +%Y%m%d-%H%M).out"
    [ ${#MODE_ARGS[@]} -gt 0 ] && default_name="tofu-destroy-targeted-$(date +%Y%m%d-%H%M).out"
    read -e -p "Plan file name [${default_name}]: " name
    name="${name:-$default_name}"
    [[ "$name" == *.out ]] || name="${name}.out"

    build_args
    print_info "Creating plan: $name"
    if run_logged "plan-${name%.out}" tofu plan -out="$name" "${VAR_ARGS[@]}" "${TUNE_ARGS[@]}" "${TARGET_ARGS[@]}" "${MODE_ARGS[@]}"; then
        LAST_PLAN="$name"; save_state
        print_success "Plan created: $name"
        echo ""
        print_info "Plan summary:"
        tofu show -no-color "$name" | grep -E "^Plan:|will be (created|destroyed|updated)" | sort | uniq -c | sort -rn | head -60 || true
        return 0
    fi
    print_error "Failed to create plan"
    return 1
}

apply_plan() {
    local plan="$1"
    print_info "Applying $plan..."
    # A saved plan already contains vars and refresh behaviour; only operational flags like -parallelism are allowed
    build_args
    if run_logged "apply-${plan%.out}" tofu apply -parallelism="$PARALLELISM" "$plan"; then
        print_success "Apply successful"
        return 0
    fi
    print_error "Apply failed - see log in $LOG_DIR/"
    return 1
}

pick_plan() {
    local plans=( *.out )
    if [ ! -e "${plans[0]}" ]; then
        print_error "No .out plan files found. Run option 1 or 2 first."
        return 1
    fi
    echo "Available plans:"
    local i=1
    for p in "${plans[@]}"; do
        local mark=""; [ "$p" = "$LAST_PLAN" ] && mark=" (last created)"
        echo "  $i) $p$mark"; i=$((i+1))
    done
    local sel
    read -p "Choose plan number [default: last created]: " sel
    if [ -z "$sel" ]; then
        [ -n "$LAST_PLAN" ] && [ -f "$LAST_PLAN" ] && SELECTED_PLAN="$LAST_PLAN" || SELECTED_PLAN="${plans[0]}"
    else
        SELECTED_PLAN="${plans[$((sel-1))]}"
    fi
    [ -f "$SELECTED_PLAN" ] || { print_error "Invalid selection"; return 1; }
}

confirm() {   # confirm "question"
    local a
    print_warning "$1 (yes/no)"
    read a
    [ "$a" = "yes" ] || [ "$a" = "y" ]
}

# ---------- Menu ----------
show_menu() {
    echo ""
    echo "========================================="
    echo "     OpenTofu Management Script"
    echo "========================================="
    echo "  vars:    ${VAR_FILE:-<not set>}"
    echo "  profile: ${AWS_PROFILE_NAME:-<not set>}"
    echo "  tuning:  parallelism=$PARALLELISM refresh=$REFRESH"
    echo "-----------------------------------------"
    echo "1) Plan Only"
    echo "2) Plan & Apply (with confirmation)"
    echo "3) Apply Existing Plan (pick a .out file)"
    echo "4) Destroy Resources"
    echo "5) Plan & Auto-Apply (no confirmation)"
    echo "6) Change vars file / profile"
    echo "7) Re-run AWS SSO login"
    echo "8) Tuning (parallelism / refresh)"
    echo "9) Targeted Plan & Apply (specific resources/modules)"
    echo "10) Targeted Destroy (specific resources/modules)"
    echo "11) Exit"
    echo "========================================="
    echo -n "Choose an option [1-11]: "
}

main() {
    command -v tofu >/dev/null || { print_error "OpenTofu is not installed."; exit 1; }
    command -v aws  >/dev/null || { print_error "AWS CLI is not installed."; exit 1; }

    load_state
    prompt_settings || exit 1
    sso_login || exit 1

    [ -d ".terraform" ] || { print_warning "Not initialized in this directory"; initialize_tofu || exit 1; }

    while true; do
        show_menu
        read choice

        case $choice in
            1)
                echo ""; print_info "Plan Only Mode"
                ensure_settings && sso_login && initialize_tofu && create_plan \
                    && print_success "Plan complete. Apply using option 3 if satisfied."
                ;;
            2)
                echo ""; print_info "Plan & Apply Mode (with confirmation)"
                if ensure_settings && sso_login && initialize_tofu && create_plan; then
                    echo ""
                    if confirm "Apply $LAST_PLAN?"; then apply_plan "$LAST_PLAN"
                    else print_warning "Apply cancelled. Plan saved as '$LAST_PLAN'"; fi
                fi
                ;;
            3)
                echo ""
                if pick_plan; then
                    sso_login || continue
                    tofu show "$SELECTED_PLAN"
                    echo ""
                    if confirm "Apply $SELECTED_PLAN?"; then apply_plan "$SELECTED_PLAN"
                    else print_warning "Apply cancelled"; fi
                fi
                ;;
            4)
                echo ""
                print_warning "DESTROY MODE - This will delete all resources!"
                echo -n "Type 'destroy' to confirm: "
                read confirm_text
                if [ "$confirm_text" = "destroy" ]; then
                    if ensure_settings && sso_login && initialize_tofu; then
                        build_args
                        print_warning "Showing what will be destroyed:"
                        run_logged "destroy-plan" tofu plan -destroy "${VAR_ARGS[@]}" "${TUNE_ARGS[@]}"
                        echo ""
                        if confirm "Proceed with destruction?"; then
                            # tofu destroy has no saved plan here, so vars are passed again
                            run_logged "destroy" tofu destroy --auto-approve "${VAR_ARGS[@]}" "${TUNE_ARGS[@]}" \
                                && print_success "Destroy successful" \
                                || print_error "Destroy failed - see log in $LOG_DIR/"
                        else
                            print_warning "Destroy cancelled"
                        fi
                    fi
                else
                    print_warning "Destroy cancelled - confirmation failed"
                fi
                ;;
            5)
                echo ""
                print_warning "AUTO-APPLY MODE - No confirmation!"
                if confirm "Proceed with plan & auto-apply?"; then
                    ensure_settings && sso_login && initialize_tofu && create_plan \
                        && apply_plan "$LAST_PLAN"
                else
                    print_warning "Auto-apply cancelled"
                fi
                ;;
            6)
                prompt_settings && sso_login
                ;;
            7)
                ensure_settings && { aws sso logout --profile "$AWS_PROFILE_NAME" 2>/dev/null; sso_login; }
                ;;
            8)
                prompt_tuning
                ;;
            9)
                echo ""; print_info "Targeted Plan & Apply Mode"
                if ensure_settings && sso_login && initialize_tofu && prompt_targets && create_plan; then
                    echo ""
                    print_warning "TARGETED plan - only the listed targets (and their dependencies) are affected."
                    if confirm "Apply $LAST_PLAN?"; then apply_plan "$LAST_PLAN"
                    else print_warning "Apply cancelled. Plan saved as '$LAST_PLAN'"; fi
                    print_info "Tip: run option 1 afterwards to see what a full plan still wants to change."
                fi
                TARGET_ARGS=()
                ;;
            10)
                echo ""; print_warning "TARGETED DESTROY MODE"
                if ensure_settings && sso_login && initialize_tofu && prompt_targets; then
                    MODE_ARGS=(-destroy)
                    if create_plan; then
                        echo ""
                        print_warning "This will DESTROY ${TARGET_ARGS[*]} AND anything that depends on it."
                        print_warning "Review the list above - dependents (e.g. instances inside a VPC) are included."
                        echo -n "Type 'destroy' to confirm: "
                        read confirm_text
                        if [ "$confirm_text" = "destroy" ]; then apply_plan "$LAST_PLAN"
                        else print_warning "Cancelled. Plan saved as '$LAST_PLAN'"; fi
                    fi
                fi
                MODE_ARGS=(); TARGET_ARGS=()
                ;;
            11)
                print_success "Exiting... (plans and logs kept; logs in $LOG_DIR/)"
                exit 0
                ;;
            *)
                print_error "Invalid option. Please choose 1-11"
                ;;
        esac

        echo ""
        read -p "Press Enter to continue..."
    done
}

main

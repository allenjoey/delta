#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CERT_MANAGER_NAMESPACE="cert-manager"
KUSTOMIZE_DIR="./cert-manager/kustomize"
TIMEOUT_SECONDS=120
INTERVAL_SECONDS=5

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    print_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed"
        exit 1
    fi

    if ! command -v kustomize &> /dev/null; then
        print_warning "kustomize not found, falling back to kubectl kustomize"
        KUSTOMIZE_CMD="kubectl kustomize"
    else
        KUSTOMIZE_CMD="kustomize"
    fi

    print_success "Prerequisites check passed"
}

namespace_exists() {
    kubectl get namespace "$CERT_MANAGER_NAMESPACE" &> /dev/null
}

deploy() {
    print_info "Deploying cert-manager..."

    # Step 1 — apply cert-manager only (excludes selfsigned-issuer.yml)
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

    print_info "Waiting for cert-manager deployments to be available (timeout: ${TIMEOUT_SECONDS}s)..."
    kubectl wait deployment -n "$CERT_MANAGER_NAMESPACE" \
        --all \
        --for=condition=Available \
        --timeout="${TIMEOUT_SECONDS}s"

    # Step 2 — wait for CRDs to be established before applying the ClusterIssuer
    print_info "Waiting for cert-manager CRDs to be established..."
    kubectl wait --for=condition=Established \
        crd/clusterissuers.cert-manager.io \
        crd/certificates.cert-manager.io \
        crd/certificaterequests.cert-manager.io \
        --timeout="${TIMEOUT_SECONDS}s"

    # Step 3 — webhook registration buffer
    print_info "Waiting for webhook registration..."
    sleep 15

    # Step 4 — now safe to apply the ClusterIssuer
    print_info "Applying ClusterIssuer..."
    kubectl apply -f "$KUSTOMIZE_DIR/selfsigned-issuer.yml"

    print_info "Verifying ClusterIssuer..."
    if kubectl get clusterissuer selfsigned-issuer &> /dev/null; then
        print_success "ClusterIssuer selfsigned-issuer is ready"
    else
        print_error "ClusterIssuer not found — check selfsigned-issuer.yml"
        exit 1
    fi

    print_success "cert-manager deployed successfully"
    status
}

teardown() {
    print_info "Starting cert-manager teardown..."

    if ! namespace_exists; then
        print_warning "Namespace $CERT_MANAGER_NAMESPACE does not exist"
        return 0
    fi

    print_warning "This will remove cert-manager and all issued certificates."
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Teardown cancelled"
        return 0
    fi

    # Remove ClusterIssuer first before cert-manager CRDs are deleted
    print_info "Removing ClusterIssuer..."
    kubectl delete -f "$KUSTOMIZE_DIR/selfsigned-issuer.yml" --ignore-not-found=true

    print_info "Removing cert-manager..."
    kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml \
        --ignore-not-found=true

    print_success "cert-manager teardown complete"
}

status() {
    print_info "cert-manager status:"

    if ! namespace_exists; then
        print_warning "Namespace $CERT_MANAGER_NAMESPACE does not exist — not deployed"
        return 0
    fi

    echo ""
    echo "=== Deployments ==="
    kubectl get deployments -n "$CERT_MANAGER_NAMESPACE"

    echo ""
    echo "=== ClusterIssuers ==="
    kubectl get clusterissuer

    echo ""
    echo "=== Certificates (all namespaces) ==="
    kubectl get certificates --all-namespaces 2>/dev/null || \
        print_warning "No certificates found yet"

    echo ""
    echo "=== CertificateRequests (all namespaces) ==="
    kubectl get certificaterequests --all-namespaces 2>/dev/null || \
        print_warning "No certificate requests found yet"
}

show_help() {
    cat << EOF
Usage: $0 {deploy|teardown|status|help}

Commands:
  deploy      Install cert-manager and create the selfsigned ClusterIssuer
  teardown    Remove cert-manager (prompts for confirmation)
  status      Show cert-manager deployments, issuers and certificates
  help        Show this help message

Examples:
  $0 deploy
  $0 status
  $0 teardown

Notes:
  - Deploy cert-manager before running deploy-jenkins.sh
  - Certificates are issued automatically when Jenkins Ingress is applied
  - To upgrade cert-manager, run teardown then deploy
EOF
}

main() {
    local command=${1:-help}

    case "$command" in
        deploy)
            check_prerequisites
            deploy
            ;;
        teardown)
            check_prerequisites
            teardown
            ;;
        status)
            check_prerequisites
            status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

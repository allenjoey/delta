#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="jenkins-server"
KUSTOMIZE_DIR="./jenkins-server/kustomize"  # Current directory, adjust if needed
TIMEOUT_SECONDS=300
INTERVAL_SECONDS=5

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if kubectl is available
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed"
        exit 1
    fi
    
    if ! command -v kustomize &> /dev/null; then
        print_warning "kustomize is not installed, will use kubectl kustomize"
        KUSTOMIZE_CMD="kubectl kustomize"
    else
        KUSTOMIZE_CMD="kustomize"
    fi
    
    print_success "Prerequisites check passed"
}

# Function to wait for pods to be ready
wait_for_pods() {
    local namespace=$1
    local timeout=$2
    local interval=$3
    local elapsed=0
    
    print_info "Waiting for pods to be ready (timeout: ${timeout}s)..."
    
    while [ $elapsed -lt $timeout ]; do
        # Get all pods in the namespace
        local not_ready_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | \
            grep -v "Running" | \
            grep -v "Completed" | \
            wc -l)
        
        local total_pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l)
        
        if [ "$total_pods" -eq 0 ]; then
            print_warning "No pods found in namespace $namespace"
            sleep $interval
            elapsed=$((elapsed + interval))
            continue
        fi
        
        if [ "$not_ready_pods" -eq 0 ]; then
            print_success "All pods are ready"
            return 0
        fi
        
        print_info "Waiting for pods to be ready ($not_ready_pods/$total_pods not ready)..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    print_error "Timeout waiting for pods to be ready"
    kubectl get pods -n "$namespace"
    return 1
}

# Function to check if namespace exists
namespace_exists() {
    kubectl get namespace "$NAMESPACE" &> /dev/null
}

# Function to deploy
deploy() {
    print_info "Starting deployment..."

    # Check if namespace exists, create if it doesn't
    if ! namespace_exists; then
        print_info "Creating namespace: $NAMESPACE"
        kubectl create namespace "$NAMESPACE"
    fi

    # Apply kustomization
    print_info "Applying kustomization from $KUSTOMIZE_DIR..."
    $KUSTOMIZE_CMD "$KUSTOMIZE_DIR" | kubectl apply -n "$NAMESPACE" -f -
    
    # Wait for pods to be ready
    if wait_for_pods "$NAMESPACE" "$TIMEOUT_SECONDS" "$INTERVAL_SECONDS"; then
        print_success "Deployment completed successfully"
        
        # Show deployment status
        print_info "Deployment status:"
        kubectl get all -n "$NAMESPACE"
        
        # Show pods with more details
        print_info "Pod details:"
        kubectl get pods -n "$NAMESPACE" -o wide
    else
        print_error "Deployment failed - pods not ready"
        exit 1
    fi
}

# Function to teardown
teardown() {
    print_info "Starting teardown..."
    
    # Check if namespace exists
    if ! namespace_exists; then
        print_warning "Namespace $NAMESPACE does not exist"
        return 0
    fi
    
    # Delete all resources from kustomization
    print_info "Deleting resources from kustomization..."
    $KUSTOMIZE_CMD "$KUSTOMIZE_DIR" | kubectl delete -f - --ignore-not-found=true
    
    # Optionally delete namespace (uncomment if you want to delete namespace too)
    # print_info "Deleting namespace: $NAMESPACE"
    # kubectl delete namespace "$NAMESPACE" --ignore-not-found=true

    # After deleting kustomization resources
    print_warning "Persistent Volume Claims may still exist"
    read -p "Delete PVCs as well? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete pvc -n "$NAMESPACE" --all --ignore-not-found=true
        print_info "PVCs deleted"
    fi

    # Wait for resources to be deleted
    print_info "Waiting for resources to be deleted..."
    sleep 10
    
    # Check remaining resources
    local remaining=$(kubectl get all -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$remaining" -eq 0 ]; then
        print_success "Teardown completed successfully"
    else
        print_warning "Some resources may still remain in namespace $NAMESPACE"
        kubectl get all -n "$NAMESPACE"
    fi
}

# Function to show status
status() {
    print_info "Current deployment status:"
    
    if ! namespace_exists; then
        print_warning "Namespace $NAMESPACE does not exist"
        return 0
    fi
    
    echo ""
    echo "=== Resources in namespace: $NAMESPACE ==="
    kubectl get all -n "$NAMESPACE"
    
    echo ""
    echo "=== Persistent Volume Claims ==="
    kubectl get pvc -n "$NAMESPACE"
    
    echo ""
    echo "=== ConfigMaps ==="
    kubectl get configmap -n "$NAMESPACE"
    
    echo ""
    echo "=== Network Policies ==="
    kubectl get networkpolicy -n "$NAMESPACE"
    
    echo ""
    echo "=== Pod Details ==="
    kubectl get pods -n "$NAMESPACE" -o wide
}

# Function to restart deployment
restart() {
    print_info "Restarting deployment..."
    teardown
    sleep 5
    deploy
}

# Function to show logs
logs() {
    local pod_name=${1:-}
    
    if ! namespace_exists; then
        print_error "Namespace $NAMESPACE does not exist"
        exit 1
    fi
    
    if [ -z "$pod_name" ]; then
        # Get all pods and show logs from first one
        pod_name=$(kubectl get pods -n "$NAMESPACE" -o name | head -1 | cut -d/ -f2)
        if [ -z "$pod_name" ]; then
            print_error "No pods found in namespace $NAMESPACE"
            exit 1
        fi
        print_info "Showing logs for pod: $pod_name"
    fi
    
    kubectl logs -n "$NAMESPACE" "$pod_name" --tail=100 -f
}

# Function to show help
show_help() {
    cat << EOF
Usage: $0 {deploy|teardown|status|restart|logs|help}

Commands:
  deploy      Deploy the application using kustomize
  teardown    Remove all resources created by kustomize
  status      Show current deployment status
  restart     Restart the deployment (teardown then deploy)
  logs        Show logs from pods (optional: pod name)
  help        Show this help message

Examples:
  $0 deploy
  $0 teardown
  $0 status
  $0 logs casa-portal-xxx
  $0 restart

Environment variables:
  NAMESPACE       Override namespace (default: jenkins-server)
  TIMEOUT_SECONDS Timeout for waiting pods (default: 300)
EOF
}

# Main script
main() {
    local command=${1:-help}
    
    # Override namespace if set via environment variable
    NAMESPACE="${NAMESPACE:-jenkins-server}"
    
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
        restart)
            check_prerequisites
            restart
            ;;
        logs)
            check_prerequisites
            logs "${2:-}"
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

# Run main function
main "$@"

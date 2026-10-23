#!/bin/bash
# Unified OpenTofu Management Script
# Usage: ./tofu-manage.sh

set -e

# Colors for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions for colored output
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Function to check command status
check_status() {
    if [ $? -eq 0 ]; then
        print_success "$1"
    else
        print_error "$2"
        exit 1
    fi
}

# Main menu
show_menu() {
    echo ""
    echo "========================================="
    echo "     OpenTofu Management Script"
    echo "========================================="
    echo "1) Plan Only"
    echo "2) Plan & Apply (with confirmation)"
    echo "3) Apply Existing Plan (plan.out)"
    echo "4) Destroy Resources"
    echo "5) Plan & Auto-Apply (no confirmation)"
    echo "6) Exit"
    echo "========================================="
    echo -n "Choose an option [1-6]: "
}

# Plan function
create_plan() {
    print_info "Creating OpenTofu plan..."
    tofu plan -out=plan.out
    check_status "Plan created successfully" "Failed to create plan"
    
    # Show summary
    echo ""
    print_info "Plan summary:"
    tofu show plan.out | grep -E "Plan:|add|change|destroy" || true
}

# Initialize function
initialize_tofu() {
    print_info "Initializing OpenTofu..."
    tofu init
    check_status "Initialization successful" "Initialization failed"
}

# Main execution
main() {
    # Check if tofu is installed
    if ! command -v tofu &> /dev/null; then
        print_error "OpenTofu is not installed. Please install it first."
        exit 1
    fi
    
    # Check if we need to initialize first (if .terraform doesn't exist)
    if [ ! -d ".terraform" ]; then
        print_warning "OpenTofu not initialized in this directory"
        initialize_tofu
    fi
    
    while true; do
        show_menu
        read choice
        
        case $choice in
            1)
                echo ""
                print_info "Plan Only Mode"
                initialize_tofu
                create_plan
                print_success "Plan generation complete. Apply using option 3 if satisfied."
                ;;
                
            2)
                echo ""
                print_info "Plan & Apply Mode (with confirmation)"
                initialize_tofu
                create_plan
                
                echo ""
                print_warning "Do you want to apply this plan? (yes/no)"
                read answer
                if [ "$answer" = "yes" ] || [ "$answer" = "y" ]; then
                    print_info "Applying OpenTofu plan..."
                    tofu apply plan.out
                    check_status "Apply successful" "Apply failed"
                    rm -f plan.out
                else
                    print_warning "Apply cancelled. Plan saved as 'plan.out'"
                fi
                ;;
                
            3)
                echo ""
                if [ -f "plan.out" ]; then
                    print_info "Existing plan found. Showing summary:"
                    tofu show plan.out
                    echo ""
                    print_warning "Apply this existing plan? (yes/no)"
                    read answer
                    if [ "$answer" = "yes" ] || [ "$answer" = "y" ]; then
                        tofu apply plan.out
                        check_status "Apply successful" "Apply failed"
                        rm -f plan.out
                    else
                        print_warning "Apply cancelled"
                    fi
                else
                    print_error "No plan.out file found. Run option 1 or 2 first."
                fi
                ;;
                
            4)
                echo ""
                print_warning "DESTROY MODE - This will delete all resources!"
                echo -n "Type 'destroy' to confirm: "
                read confirm
                if [ "$confirm" = "destroy" ]; then
                    print_info "Initializing before destroy..."
                    initialize_tofu
                    echo ""
                    print_warning "Showing what will be destroyed:"
                    tofu plan -destroy
                    echo ""
                    print_warning "Proceed with destruction? (yes/no)"
                    read answer
                    if [ "$answer" = "yes" ] || [ "$answer" = "y" ]; then
                        print_info "Destroying resources..."
                        tofu destroy --auto-approve
                        check_status "Destroy successful" "Destroy failed"
                    else
                        print_warning "Destroy cancelled"
                    fi
                else
                    print_warning "Destroy cancelled - confirmation failed"
                fi
                ;;
                
            5)
                echo ""
                print_warning "AUTO-APPLY MODE - No confirmation!"
                echo -n "Proceed with plan & auto-apply? (yes/no): "
                read confirm
                if [ "$confirm" = "yes" ] || [ "$confirm" = "y" ]; then
                    initialize_tofu
                    create_plan
                    print_info "Auto-applying plan..."
                    tofu apply --auto-approve plan.out
                    check_status "Auto-apply successful" "Auto-apply failed"
                    rm -f plan.out
                else
                    print_warning "Auto-apply cancelled"
                fi
                ;;
                
            6)
                print_success "Exiting..."
                # Cleanup temporary files
                rm -f plan.out 2>/dev/null
                exit 0
                ;;
                
            *)
                print_error "Invalid option. Please choose 1-6"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run main function
main
#!/bin/bash

# 1. Capture the two lists
backplane_list=$(acli net.list | grep "backplane")
vmtraffic_list=$(acli net.list | grep "VmTraffic")

# 2. PRE-PROCESS SUMMARY
echo "========================================================================================================================"
echo "                                     NETWORK MAPPING SUMMARY"
echo "========================================================================================================================"
printf "%-40s %-38s %-38s\n" "SUBNET NAME" "BACKPLANE UUID" "VMTRAFFIC UUID"
echo "------------------------------------------------------------------------------------------------------------------------"

echo "$backplane_list" | while read -r line; do
    s_name=$(echo "$line" | awk '{print $1}')
    s_bp_uuid=$(echo "$line" | awk '{print $2}')
    s_vt_uuid=$(echo "$vmtraffic_list" | grep "^$s_name " | awk '{print $2}')
    [ -z "$s_vt_uuid" ] && s_vt_uuid="NOT_FOUND"
    printf "%-40s %-38s %-38s\n" "$s_name" "$s_bp_uuid" "$s_vt_uuid"
done

echo "========================================================================================================================"
read -p "Summary complete. Press [Enter] to begin detailed NIC parsing..." < /dev/tty
echo ""

# 3. DETAILED PARSING & MIGRATION LOGIC
echo "$backplane_list" | while read -r line; do
    subnet_name=$(echo "$line" | awk '{print $1}')
    backplane_uuid=$(echo "$line" | awk '{print $2}')
    vmtraffic_uuid=$(echo "$vmtraffic_list" | grep "^$subnet_name " | awk '{print $2}')

    if [ -z "$vmtraffic_uuid" ]; then
        vmtraffic_uuid="N/A"
        nic_count=0
    else
        raw_nics=$(acli net.list_vms "$backplane_uuid")
        nic_count=$(echo "$raw_nics" | awk 'NR>1' | wc -l)
    fi

    echo "================================================================================================================================================================"
    echo "DETAILED VIEW: $subnet_name"
    echo "Total NICs: $nic_count"
    echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
    
    if [ "$nic_count" -gt 0 ]; then
        printf "%-25s %-18s %-15s %-38s %-38s\n" "VM NAME" "MAC ADDRESS" "IP ADDRESS" "CURRENT (BACKPLANE)" "DESTINATION (VMTRAFFIC)"
        echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------"
        echo "$raw_nics" | awk -v bp="$backplane_uuid" -v vt="$vmtraffic_uuid" 'NR>1 {printf "%-25s %-18s %-15s %-38s %-38s\n", $2, $3, $4, bp, vt}'
        echo "================================================================================================================================================================"
        
        # Validation Loop for Subnet Migration
        while true; do
            echo -n "Migrate the above NICs(one-by-one)? (y/n): "
            read -n 1 subnet_choice < /dev/tty
            echo ""
            if [[ "$subnet_choice" =~ ^[YyNn]$ ]]; then break; fi
            echo "Invalid input. Please press 'y' for Yes or 'n' for No."
        done

        if [[ "$subnet_choice" =~ ^[Yy]$ ]]; then
            echo "$raw_nics" | tail -n +2 | while read -r vm_uuid vm_name mac_addr ip_addr; do
                echo ""
                echo "--> Target: $vm_name"
                
                # Pre-check ping test
                pre_check_ok=false
                if [[ -n "$ip_addr" && "$ip_addr" != "-" ]]; then
                    echo "[PRE-CHECK] Testing connectivity to $ip_addr (2 packets)..."
                    if ping -c 2 -W 2 "$ip_addr" > /dev/null 2>&1; then
                        echo "[PRE-CHECK] ✓ Ping successful"
                        pre_check_ok=true
                    else
                        echo -e "\033[0;33m[PRE-CHECK] ✗ Ping failed (host may be down or unreachable)\033[0m"
                    fi
                else
                    echo "[INFO] No IP address assigned, skipping ping tests"
                fi
                
                # Validation Loop for Individual NIC
                while true; do
                    echo -n "Do you want to move this one NIC to the destination vSwitch? (y/n): "
                    read -n 1 nic_choice < /dev/tty
                    echo ""
                    if [[ "$nic_choice" =~ ^[YyNn]$ ]]; then break; fi
                    echo "Invalid input. Please press 'y' or 'n'."
                done

                if [[ "$nic_choice" =~ ^[Yy]$ ]]; then
                    # Build command with conditional IP argument
                    if [[ -n "$ip_addr" && "$ip_addr" != "-" ]]; then
                        cmd="acli vm.nic_update $vm_name $mac_addr network=$vmtraffic_uuid ip=$ip_addr"
                    else
                        cmd="acli vm.nic_update $vm_name $mac_addr network=$vmtraffic_uuid"
                    fi
                    
                    echo "[ACTION] Executing migration..."
                    echo "Command: $cmd"
                    $cmd
                    
                    # Post-check ping test
                    if [[ -n "$ip_addr" && "$ip_addr" != "-" ]]; then
                        echo "[POST-CHECK] Testing connectivity to $ip_addr..."
                        sleep 2  # Brief pause to allow network to stabilize
                        
                        if ping -c 2 -W 2 "$ip_addr" > /dev/null 2>&1; then
                            if [ "$pre_check_ok" = true ]; then
                                echo -e "\033[0;32m[POST-CHECK] ✓ Migration successful - host is reachable\033[0m"
                            else
                                echo "[POST-CHECK] ✓ Ping successful (though pre-check failed)"
                            fi
                        else
                            # Only retry if pre-check was successful
                            if [ "$pre_check_ok" = true ]; then
                                echo "[POST-CHECK] First attempt failed, retrying with 5 packets..."
                                sleep 3
                                if ping -c 5 -W 2 "$ip_addr" > /dev/null 2>&1; then
                                    echo -e "\033[0;32m[POST-CHECK] ✓ Migration successful - host is reachable (after retry)\033[0m"
                                else
                                    echo -e "\033[0;31m[POST-CHECK] ✗ WARNING: Host not reachable after migration! Check VM and network configuration.\033[0m"
                                fi
                            else
                                echo -e "\033[0;33m[POST-CHECK] ✗ Ping failed (pre-check also failed)\033[0m"
                            fi
                        fi
                    fi
                else
                    echo "Result: Skipped $vm_name."
                fi
            done
        else
            echo "Result: Skipping subnet $subnet_name."
        fi
    else
        echo "No VMs found in this subnet."
    fi

    echo ""
done
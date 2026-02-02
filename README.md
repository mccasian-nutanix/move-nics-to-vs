# NIC Migration Between Virtual Switches

## Overview

This script facilitates the migration of network interfaces (NICs) from one Nutanix virtual switch to another. It parses subnets and their associated NICs, then provides an interactive interface for selective migration with automated connectivity validation.

## Prerequisites

Before running this script, ensure you have:

1. **Cloned Subnets**: Use the [`clone_subnets.py`](../clone_subnets/clone_subnets.py) script to create duplicate subnets on the destination virtual switch
2. **SSH Access**: Either direct CVM access or SSH forwarding enabled from your jump host
3. **Permissions**: The ssh key needs to be added to Nutanix cluster -> Login to Prism Element with "admin" account(admin itself not any admin account) -> Cluster Lockdown -> + New Public Key
4. **Network Connectivity**: Ability to ping target NIC IPs for pre/post-migration validation

## Usage

### Remote Execution (from Jump Host/Gateway) - **RECOMMENDED**

```bash
./move_nics.sh -c <cluster_fqdn>
```

**Example:**
```bash
./move_nics.sh -c spacex.nasa.com
```

### Local Execution (from CVM) - **LIMITED FUNCTIONALITY**

```bash
./move_nics_from_cvm.sh
```

**⚠️ CVM Version Limitations:**
- Pre-check and post-check ping tests cannot validate frontend-connected NICs from backend-connected CVMs
- Connectivity validation may be unreliable due to network segmentation
- Use the remote version whenever possible for full validation capabilities

## Features

- **Interactive Virtual Switch Selection**: Choose source and destination virtual switches using arrow-key navigation (alphabetically sorted)
- **Subnet Discovery**: Automatically identifies subnets present on both virtual switches
- **Per-NIC Migration**: Selective migration with y/n confirmation for each network interface
- **Automated Connectivity Validation**:
  - **Pre-check**: 2-packet ping test before migration to establish baseline
  - **Post-check**: 2-packet ping test after migration with automatic retry (5 packets) if pre-check succeeded
  - **Color-coded results**:
    - 🟢 **Green**: Migration successful, host reachable
    - 🔴 **Red**: Migration issue - host was reachable before but not after (needs investigation)
    - 🟡 **Yellow**: Expected failure - host was unreachable before and after migration
- **Subnet Cleanup**: Option to delete source subnet after all NICs are successfully migrated
- **Safety Validation**: Prevents migration when source and destination switches are identical

## SSH Configuration

### For Remote Execution

When executing from a jump host (e.g., segment gateway), enable SSH agent forwarding for seamless authentication:

**Using OpenSSH:**
```bash
ssh -A user@gateway
```

**Using PuTTY:**
Enable "Allow agent forwarding" in Connection → SSH → Auth settings

This allows the script to authenticate to Nutanix clusters without storing credentials on the gateway.

## Script Versions Comparison

| Feature | Remote (`move_nics.sh`) | CVM (`move_nics_from_cvm.sh`) |
|---------|-------------------------|--------------------------------|
| Execution Location | Jump host/Gateway | Directly on CVM |
| SSH Requirement | Yes (to cluster) | No (local ACLI) |
| Pre/Post-check Validation | ✅ Full validation | ⚠️ Limited (backend only) |
| Frontend NIC Testing | ✅ Yes | ❌ No (network segmentation) |
| Interactive vSwitch Selection | ✅ Yes | ❌ No (hardcoded backplane/VmTraffic) |
| Recommended Use | Primary method | Fallback only |

**Why use the remote version?**
The remote version can ping and validate frontend-connected NICs because it runs from a jump host/gateway that typically has routing to both backend and frontend networks. The CVM version runs on the backend network and cannot reach frontend-connected VMs due to network segmentation, making pre/post-check validation unreliable or impossible for most production workloads.

## Workflow

1. **Connect** to the specified cluster
2. **Fetch** available virtual switches (sorted alphabetically)
3. **Select** source and destination switches interactively
4. **Review** network mapping summary showing subnet UUIDs on both switches
5. **For each NIC**:
   - Display VM name and IP address
   - Run **pre-check** ping test (2 packets) to verify current connectivity
   - Prompt for migration confirmation
   - Execute migration command
   - Run **post-check** ping test (2 packets) with automatic retry if needed
   - Display color-coded result (green/red/yellow)
6. **Subnet cleanup**: After all NICs in a subnet are migrated, option to delete the source subnet

## Notes

- **Connectivity Validation**: Automated ping tests run before and after each migration to verify network connectivity
  - NICs without IP addresses skip ping tests automatically
  - Post-check includes intelligent retry logic (5 packets) if pre-check was successful
- **Color-Coded Feedback**: Immediate visual indication of migration success or issues
- **Network Segmentation**: The remote version (`move_nics.sh`) can validate frontend-connected NICs, while the CVM version may have limited reach due to backend/frontend network separation
- **Subnet Deletion**: Source subnets can be cleaned up automatically after successful migration of all NICs to reduce configuration clutter
- Migration can be aborted at any subnet or individual NIC level by answering 'n' to prompts

## Example Output

```
--> Target: webserver01

[PRE-CHECK] Testing connectivity to 10.20.30.40 (2 packets)...
[PRE-CHECK] ✓ Ping successful
Do you want to move this one NIC to the destination vSwitch? (y/n): y

[ACTION] Executing remote update...(acli vm.nic_update webserver01 00:50:56:ab:cd:ef network=uuid123 ip=10.20.30.40)
[POST-CHECK] Testing connectivity to 10.20.30.40...
[POST-CHECK] ✓ Migration successful - host is reachable  # Green text
```

**Failed Migration Example (Red - Needs Investigation):**
```
[PRE-CHECK] ✓ Ping successful
[POST-CHECK] First attempt failed, retrying with 5 packets...
[POST-CHECK] ✗ WARNING: Host not reachable after migration! Check VM and network configuration.  # Red text
```

**Expected Failure Example (Yellow - Host Already Down):**
```
[PRE-CHECK] ✗ Ping failed (host may be down or unreachable)  # Yellow text
[POST-CHECK] ✗ Ping failed (pre-check also failed)  # Yellow text
```

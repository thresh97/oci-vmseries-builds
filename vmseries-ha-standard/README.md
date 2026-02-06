# OCI Palo Alto VM-Series HA Deployment

## Overview

This Terraform configuration automates the deployment of a high-availability (HA) network security architecture in Oracle Cloud Infrastructure (OCI). It features a pair of Palo Alto Networks VM-Series Next-Generation Firewalls (NGFW) in an Active/Passive configuration, protecting a backend Linux workload.

The deployment is designed to be region-agnostic and resilient, utilizing Terraform functions for dynamic CIDR calculation and modular arithmetic for Availability Domain (AD) selection.

## Architecture Components

### Networking

- **Virtual Cloud Network (VCN):** A single VCN with a configurable CIDR (default `10.0.0.0/16`).
    
- **Subnets:** Five distinct subnets are dynamically calculated using the `cidrsubnet` function:
    
    1. **Management (`mgmt`):** For administrative access to the firewalls.
        
    2. **Untrust (`untrust`):** Public-facing side of the firewalls.
        
    3. **Trust (`trust`):** Internal side of the firewalls for protected traffic.
        
    4. **HA2 (`ha2`):** Dedicated synchronization and heartbeat link between the firewalls.
        
    5. **Workload (`workload`):** Private subnet for backend services (Linux Worker).
        
- **Routing:**
    
    - A custom route table is applied to the **Workload** subnet.
        
    - **Default Route (0.0.0.0/0):** Points to the **Trust Floating IP** (VIP), forcing all egress traffic through the firewall.
        
    - **Management Bypass:** Specific routes for defined management CIDRs point directly to the Internet Gateway to maintain connectivity.
        

### Compute Instances

- **Firewalls:** Two Palo Alto VM-Series instances deployed across different ADs (where available).
    
    - Each firewall is equipped with 4 VNICs (Management, Untrust, Trust, HA2).
        
    - High-performance Standard3 Flex shapes are used by default.
        
- **Workload:** One Oracle Linux 9 (ARM-based A1) instance acting as a protected worker node.
    

### Identity & Access

- **Dynamic Group:** Automatically groups the two firewall instances.
    
- **Identity Policy:** Grants the firewalls permission to manage networking and instance resources, enabling automated HA failover (floating IP migration).
    

## Prerequisites

- OCI Tenancy OCID and Compartment OCID.
    
- SSH Public Key for instance access.
    
- Valid Palo Alto Networks BYOL licenses (or marketplace subscription).
    
- Terraform v1.0.0 or later.
    

## Usage

1. Initialize the directory: `terraform init`
    
2. Provide required variables (bootstrap config, compartment ID, etc.).
    
3. Preview the plan: `terraform plan`
    
4. Apply the configuration: `terraform apply`
    

## Firewall Configuration & Verification

After the firewalls have booted and bootstrapped, log in via SSH to verify and configure performance-critical settings.

### DPDK / VFIO Packet I/O

For high-throughput performance on OCI shapes, ensure DPDK is enabled and using the correct driver.

- **Verify setting:**
    
    ```
    show system setting dpdk-pkt-io
    ```
    
- **Configure setting (requires reboot):**
    
    ```
    set system setting dpdk-pkt-io <on|off>
    ```
    

### Jumbo Frames

OCI has Jumbo Frames enabled by default. The VM-Series is configured to process these larger packets using the bootstrap parameter `op-command-modes=jumbo-frame`.

- **Verify setting:**
    
    ```
    show system setting jumbo-frame
    ```
    
- **Configure setting (requires reboot):**
    
    ```
    set system setting jumbo-frame <on|off>
    ```
    
    _Note: After enabling jumbo frames, ensure the MTU size configured on the PAN-OS interfaces aligns with the "Current device mtu size" (typically 9192 for OCI)._
    

### High Availability (HA) Configuration

**Important Note:** As of **SCM 2025.r5.0**, Active/Passive HA cannot be configured via SCM if the management port is used for **HA1**. If this configuration is desired, HA must be configured locally on each firewall. **HA1 should specifically be configured to use the management port.**

Use the following CLI commands as a reference for local configuration:

**Firewall 1 (oci-ha-fw1):**

```
set network interface ethernet ethernet1/3 ha
set deviceconfig system hostname oci-ha-fw1
set deviceconfig high-availability interface ha1 port management
set deviceconfig high-availability interface ha2 ip-address 10.0.4.2
set deviceconfig high-availability interface ha2 netmask 255.255.255.0
set deviceconfig high-availability interface ha2 gateway 10.0.4.1
set deviceconfig high-availability interface ha2 port ethernet1/3
set deviceconfig high-availability group mode active-passive 
set deviceconfig high-availability group group-id 63
set deviceconfig high-availability group peer-ip 10.0.1.3
set deviceconfig high-availability group state-synchronization enabled yes
set deviceconfig high-availability group state-synchronization transport udp
set deviceconfig high-availability group election-option device-priority 100
set deviceconfig high-availability enabled yes
set deviceconfig setting advance-routing yes
```

**Firewall 2 (oci-ha-fw2):**

```
set network interface ethernet ethernet1/3 ha
set deviceconfig system hostname oci-ha-fw2
set deviceconfig high-availability interface ha1 port management
set deviceconfig high-availability interface ha2 ip-address 10.0.4.3
set deviceconfig high-availability interface ha2 netmask 255.255.255.0
set deviceconfig high-availability interface ha2 gateway 10.0.4.1
set deviceconfig high-availability interface ha2 port ethernet1/3
set deviceconfig high-availability group mode active-passive 
set deviceconfig high-availability group group-id 63
set deviceconfig high-availability group peer-ip 10.0.1.2
set deviceconfig high-availability group state-synchronization enabled yes
set deviceconfig high-availability group state-synchronization transport udp
set deviceconfig high-availability group election-option device-priority 101
set deviceconfig high-availability enabled yes
set deviceconfig setting advance-routing yes
```

## SCM Folder Configuration Checklist

When configuring the SCM Folder for this deployment pattern, ensure the following settings are implemented:

1. **Interfaces:** Assign the correct Private IPs to the Trust and Untrust dataplane interfaces.
    
2. **MTU:** Set interface MTU to **9192** to align with OCI Jumbo Frame standards.
    
3. **Untrust Routing:** Configure a Default Route (0.0.0.0/0) pointing to the Untrust gateway (usually .1 of the untrust subnet).
    
4. **Trust Routing:** Add a static route for the workload subnet (e.g., `10.0.5.0/24`) pointing to the OCI default gateway of the trust subnet (e.g., `10.0.3.1`).
    
5. **NAT:** Configure an Egress Source NAT (Dynamic IP/Port) policy on the Untrust interface to enable internet access for internal workloads.
    
6. **Security Policy:** Create policies to permit required traffic flows between zones.
    

## Post-Deployment Verification

Outbound access and NAT verification for the workload can be tested using the Linux worker node:

1. Obtain the **Public IP** of the `linux-worker-vm` from the Terraform outputs.
    
2. From a management IP allowed in `allowed_mgmt_cidrs`, connect via SSH:
    
    ```
    ssh opc@<linux_worker_public_ip>
    ```
    
3. Execute verification commands to test firewall transit and verify the exit IP (should match the **untrust_floating_public_ip**):
    
    ```
    ping -c 4 8.8.8.8
    curl ifconfig.co
    ```
    

## Deployment Commands Reference

To discover available Marketplace listings or package versions, you can use the following OCI CLI commands (replace `<compartment_ocid>` with your own):

```
# List all Palo Alto listings
oci marketplace listing list --all --compartment-id <compartment_ocid> --query "data[?publisher.name == 'Palo Alto Networks'].{Name: name, ID: id, Pricing: join(', ', \"pricing-types\")}" --output table

# List VM-Series BYOL packages/versions for a specific listing
oci marketplace package list --listing-id <listing_ocid> --compartment-id <compartment_ocid> --query "data[].{Version: \"package-version\", PackageID: \"resource-id\", Type: \"package-type\"}" --output table
```

## Disclaimer

**FOR TEST AND DEMO USE ONLY.**

This code is provided "as is" without warranty of any kind, either expressed or implied, including but not limited to the implied warranties of merchantability and fitness for a particular purpose. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

This is a reference architecture and should be thoroughly reviewed and modified to meet your organization's specific security and compliance requirements before use in a production environment.

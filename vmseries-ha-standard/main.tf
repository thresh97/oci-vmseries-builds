# --- PROVIDER CONFIGURATION ---
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 4.0.0"
    }
  }
}

provider "oci" {
  auth   = var.oci_auth_method
  region = var.region
}

# --- VARIABLES ---

variable "oci_auth_method" {
  type        = string
  description = "Strategy for auth: 'InstancePrincipal' for Cloud Shell, 'SecurityToken' for local session"
  default     = "InstancePrincipal"
}

variable "region" {
  type    = string
  default = "us-phoenix-1"
}

variable "tenancy_ocid" {
  type        = string
  description = "The OCID of your OCI tenancy (Root Compartment)"
}

variable "compartment_id" {
  type        = string
}

variable "ssh_public_key" {
  type        = string
}

variable "allowed_mgmt_cidrs" {
  type        = list(string)
  description = "List of CIDR blocks allowed to access the management interfaces via SSH and Ping"
  default     = ["0.0.0.0/0"]
}

variable "vcn_cidr" {
  type        = string
  description = "The CIDR block for the VCN"
  default     = "10.0.0.0/16"
}

variable "subnet_mask_size" {
  type        = number
  description = "The bits to add to the VCN CIDR for subnets (e.g., 8 to turn /16 into /24)"
  default     = 8
}

variable "linux_user_data_raw" {
  type        = string
  description = "Raw text for Linux cloud-init. Terraform will base64 encode this for the instance."
  default     = <<-EOF
    #cloud-config
    packages:
      - nginx
    runcmd:
      - systemctl enable nginx
      - systemctl start nginx
      - echo "<h1>Deployed via Terraform on Oracle Linux ARM</h1>" > /usr/share/nginx/html/index.html
    EOF
}

variable "vmseries_bootstrap_custom_1" {
  type        = string
  description = "Custom bootstrap configuration for VM-Series 1."
}

variable "vmseries_bootstrap_custom_2" {
  type        = string
  description = "Custom bootstrap configuration for VM-Series 2."
}

variable "mp_listing_name" {
  type        = string
  description = "Marketplace listing name for the VM-Series firewall"
  default     = "Palo Alto Networks VM-Series Next Generation Firewall"
}

variable "mp_pricing_type" {
  type        = string
  description = "Marketplace pricing type (e.g., BYOL, PAYG)"
  default     = "BYOL"
}

variable "mp_listing_resource_version" {
  type        = string
  description = "Specific version of the Palo Alto image"
  default     = "12.1.2"
}

variable "panos_version" {
  type        = string
  description = "Version of PAN-OS to use"
  default     = "12.1.2"
}

variable "vmseries_shape" {
  type        = string
  description = "The shape for the VM-Series instances."
  default     = "VM.Standard3.Flex"
}

variable "vmseries_ocpus" {
  type        = number
  description = "Number of OCPUs for VM-Series. Standard3 Flex shapes allow 1 VNIC per OCPU."
  default     = 4
}

variable "vmseries_memory" {
  type        = number
  description = "Memory in GBs for VM-Series."
  default     = 16
}

# --- DATA SOURCES ---

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

# --- MARKETPLACE LISTING DISCOVERY ---
# CLI of all Palo Alto Networks Marketplace Listings:
# oci marketplace listing list --all --compartment-id <compartment_ocid> --query "data[?publisher.name == 'Palo Alto Networks'].{Name: name, ID: id, Pricing: join(', ', \"pricing-types\")}" --output table

# All Non-Government Cloud VM-Series BYOL listings:
# oci marketplace listing list --all --compartment-id <compartment_ocid> --query "data[?contains(name, 'VM-Series') && publisher.name == 'Palo Alto Networks' && starts_with(name, 'Palo Alto')].{Name: name, ID: id, Pricing: join(', ', \"pricing-types\")}" --output table

# CLI to list marketplace packages of a specific listing ID:
# oci marketplace package list --listing-id ocid1.mktpublisting.oc1.iad.amaaaaaa4dbpobaa5n4zub3tpa3muwtrj6mumc44z6n7xmvx2w2jpovdfaxa --compartment-id <compartment_ocid> --query "data[].{Version: \"package-version\", PackageID: \"resource-id\", Type: \"package-type\"}" --output table

data "oci_marketplace_listings" "pa_listing" {
  compartment_id = var.compartment_id
  name           = [var.mp_listing_name]
  pricing        = [var.mp_pricing_type]
}

data "oci_marketplace_listing_package" "pa_package" {
  listing_id      = data.oci_marketplace_listings.pa_listing.listings[0].id
  package_version = var.mp_listing_resource_version
}

data "oci_core_images" "linux_image" {
  compartment_id = var.compartment_id
  state          = "AVAILABLE"
  sort_by        = "TIMECREATED"
  sort_order     = "DESC"

  filter {
    name   = "display_name"
    values = ["Oracle-Linux-9.6-aarch64-2025.11.20-0"]
  }
}

# --- LOCALS ---
locals {
  # Subnet Index Mapping
  subnet_idx = {
    mgmt     = 1
    untrust  = 2
    trust    = 3
    ha2      = 4
    workload = 5
  }

  # Resilient AD Selection using Modular Arithmetic
  ad_count = length(data.oci_identity_availability_domains.ads.availability_domains)
  ad_1     = data.oci_identity_availability_domains.ads.availability_domains[0].name
  ad_2     = data.oci_identity_availability_domains.ads.availability_domains[1 % local.ad_count].name
}

# --- MARKETPLACE AGREEMENT ---
resource "oci_core_app_catalog_listing_resource_version_agreement" "pa_agreement" {
  listing_id               = data.oci_marketplace_listing_package.pa_package.app_catalog_listing_id
  listing_resource_version = data.oci_marketplace_listing_package.pa_package.app_catalog_listing_resource_version
}

resource "oci_core_app_catalog_subscription" "pa_subscription" {
  compartment_id           = var.compartment_id
  listing_id               = data.oci_marketplace_listing_package.pa_package.app_catalog_listing_id
  listing_resource_version = data.oci_marketplace_listing_package.pa_package.app_catalog_listing_resource_version
  oracle_terms_of_use_link = oci_core_app_catalog_listing_resource_version_agreement.pa_agreement.oracle_terms_of_use_link
  eula_link                = oci_core_app_catalog_listing_resource_version_agreement.pa_agreement.eula_link
  time_retrieved           = oci_core_app_catalog_listing_resource_version_agreement.pa_agreement.time_retrieved
  signature                = oci_core_app_catalog_listing_resource_version_agreement.pa_agreement.signature
}

# --- NETWORKING ---

resource "oci_core_vcn" "fw_vcn" {
  cidr_block     = var.vcn_cidr
  compartment_id = var.compartment_id
  display_name   = "palo_alto_vcn"
  dns_label      = "pavcn"
}

resource "oci_core_internet_gateway" "ig" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.fw_vcn.id
}

# Default Route Table (Edge)
resource "oci_core_default_route_table" "default_route" {
  manage_default_resource_id = oci_core_vcn.fw_vcn.default_route_table_id
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.ig.id
  }
}

# Workload Route Table (Transit through Firewall)
resource "oci_core_route_table" "workload_route" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.fw_vcn.id
  display_name   = "workload_route_table"

  # Default route points to the Firewall Trust VIP
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_private_ip.trust_floating_ip.id
    destination_type  = "CIDR_BLOCK"
  }

  # Management bypass: Specific routes to trusted IPs go direct to IGW
  dynamic "route_rules" {
    for_each = var.allowed_mgmt_cidrs
    content {
      destination       = route_rules.value
      network_entity_id = oci_core_internet_gateway.ig.id
      destination_type  = "CIDR_BLOCK"
    }
  }
}

# --- SECURITY LISTS ---

# Management Security List
resource "oci_core_security_list" "mgmt_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.fw_vcn.id
  display_name   = "mgmt_security_list"

  ingress_security_rules {
    protocol    = "all"
    source      = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.mgmt)
    description = "Allow all traffic within management subnet"
  }

  dynamic "ingress_security_rules" {
    for_each = var.allowed_mgmt_cidrs
    content {
      protocol = "6"
      source   = ingress_security_rules.value
      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.allowed_mgmt_cidrs
    content {
      protocol = "6"
      source   = ingress_security_rules.value
      tcp_options {
        min = 80
        max = 80
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = var.allowed_mgmt_cidrs
    content {
      protocol = "1"
      source   = ingress_security_rules.value
      icmp_options {
        type = 8
      }
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Untrust Security List (No inbound from Internet)
resource "oci_core_security_list" "untrust_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.fw_vcn.id
  display_name   = "untrust_dataplane_security_list"

  # No ingress rules = drop all inbound by default in OCI
  
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Trust Security List (Allow inbound from Workload)
resource "oci_core_security_list" "trust_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.fw_vcn.id
  display_name   = "trust_dataplane_security_list"

  ingress_security_rules {
    protocol    = "all"
    source      = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.workload)
    description = "Allow all traffic from the workload subnet for firewall inspection"
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# HA2 Security List
resource "oci_core_security_list" "ha2_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.fw_vcn.id
  display_name   = "ha2_security_list"

  ingress_security_rules {
    protocol = "all"
    source   = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.ha2)
  }

  egress_security_rules {
    protocol    = "all"
    destination = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.ha2)
  }
}

# Subnets
resource "oci_core_subnet" "mgmt_subnet" {
  cidr_block        = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.mgmt)
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.fw_vcn.id
  display_name      = "mgmt_subnet"
  dns_label         = "mgmt"
  security_list_ids = [oci_core_security_list.mgmt_security_list.id]
}

resource "oci_core_subnet" "untrust_subnet" {
  cidr_block        = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.untrust)
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.fw_vcn.id
  display_name      = "untrust_subnet"
  dns_label         = "untrust"
  security_list_ids = [oci_core_security_list.untrust_security_list.id]
}

resource "oci_core_subnet" "trust_subnet" {
  cidr_block        = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.trust)
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.fw_vcn.id
  display_name      = "trust_subnet"
  dns_label         = "trust"
  security_list_ids = [oci_core_security_list.trust_security_list.id]
}

resource "oci_core_subnet" "ha2_subnet" {
  cidr_block        = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.ha2)
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.fw_vcn.id
  display_name      = "ha2_subnet"
  dns_label         = "ha2"
  security_list_ids = [oci_core_security_list.ha2_security_list.id]
}

resource "oci_core_subnet" "workload_subnet" {
  cidr_block     = cidrsubnet(var.vcn_cidr, var.subnet_mask_size, local.subnet_idx.workload)
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.fw_vcn.id
  display_name   = "workload_subnet"
  dns_label      = "workload"
  route_table_id = oci_core_route_table.workload_route.id
}

# --- IDENTITY RESOURCES ---

resource "oci_identity_dynamic_group" "pa_ha_group" {
  compartment_id = var.tenancy_ocid
  name           = "PA-VM-HA-Group"
  description    = "Dynamic group for Palo Alto VM-Series HA pair"
  matching_rule  = "Any {instance.id = '${oci_core_instance.palo_alto_vm_1.id}', instance.id = '${oci_core_instance.palo_alto_vm_2.id}'}"
}

resource "oci_identity_policy" "pa_ha_policy" {
  compartment_id = var.compartment_id
  name           = "PA-VM-HA-Policy"
  description    = "Policy allowing PA-VM instances to perform HA operations"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.pa_ha_group.name} to use virtual-network-family in compartment id ${var.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.pa_ha_group.name} to use instance-family in compartment id ${var.compartment_id}"
  ]
}

# --- COMPUTE (PALO ALTO VM-SERIES 1) ---

resource "oci_core_instance" "palo_alto_vm_1" {
  availability_domain = local.ad_1
  compartment_id      = var.compartment_id
  display_name        = "palo-alto-firewall-1"
  shape               = var.vmseries_shape

  shape_config {
    ocpus         = var.vmseries_ocpus
    memory_in_gbs = var.vmseries_memory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.mgmt_subnet.id
    display_name     = "mgmt_interface"
    assign_public_ip = true
    private_ip       = cidrhost(oci_core_subnet.mgmt_subnet.cidr_block, 2)
  }

  source_details {
    source_type = "image"
    source_id   = "ocid1.image.oc1..aaaaaaaa4gdtugm5e7vhkbfp5w44yijpvzwigdso2ogbfvjscmfipk55blva"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(var.vmseries_bootstrap_custom_1)
  }

  depends_on = [oci_core_app_catalog_subscription.pa_subscription]
}

resource "oci_core_vnic_attachment" "pa1_untrust_vnic" {
  instance_id  = oci_core_instance.palo_alto_vm_1.id
  display_name = "untrust_vnic_1"
  create_vnic_details {
    subnet_id              = oci_core_subnet.untrust_subnet.id
    private_ip             = cidrhost(oci_core_subnet.untrust_subnet.cidr_block, 2)
    skip_source_dest_check = true
    assign_public_ip       = true
  }
}

resource "oci_core_vnic_attachment" "pa1_trust_vnic" {
  instance_id  = oci_core_instance.palo_alto_vm_1.id
  display_name = "trust_vnic_1"
  create_vnic_details {
    subnet_id              = oci_core_subnet.trust_subnet.id
    private_ip             = cidrhost(oci_core_subnet.trust_subnet.cidr_block, 2)
    skip_source_dest_check = true
  }
  depends_on = [oci_core_vnic_attachment.pa1_untrust_vnic]
}

resource "oci_core_vnic_attachment" "pa1_ha2_vnic" {
  instance_id  = oci_core_instance.palo_alto_vm_1.id
  display_name = "ha2_vnic_1"
  create_vnic_details {
    subnet_id  = oci_core_subnet.ha2_subnet.id
    private_ip = cidrhost(oci_core_subnet.ha2_subnet.cidr_block, 2)
  }
  depends_on = [oci_core_vnic_attachment.pa1_trust_vnic]
}

# --- COMPUTE (PALO ALTO VM-SERIES 2) ---

resource "oci_core_instance" "palo_alto_vm_2" {
  availability_domain = local.ad_2
  compartment_id      = var.compartment_id
  display_name        = "palo-alto-firewall-2"
  shape               = var.vmseries_shape

  shape_config {
    ocpus         = var.vmseries_ocpus
    memory_in_gbs = var.vmseries_memory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.mgmt_subnet.id
    display_name     = "mgmt_interface"
    assign_public_ip = true
    private_ip       = cidrhost(oci_core_subnet.mgmt_subnet.cidr_block, 3)
  }

  source_details {
    source_type = "image"
    source_id   = "ocid1.image.oc1..aaaaaaaa4gdtugm5e7vhkbfp5w44yijpvzwigdso2ogbfvjscmfipk55blva"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(var.vmseries_bootstrap_custom_2)
  }

  depends_on = [oci_core_app_catalog_subscription.pa_subscription]
}

resource "oci_core_vnic_attachment" "pa2_untrust_vnic" {
  instance_id  = oci_core_instance.palo_alto_vm_2.id
  display_name = "untrust_vnic_2"
  create_vnic_details {
    subnet_id              = oci_core_subnet.untrust_subnet.id
    private_ip             = cidrhost(oci_core_subnet.untrust_subnet.cidr_block, 3)
    skip_source_dest_check = true
    assign_public_ip       = true
  }
}

resource "oci_core_vnic_attachment" "pa2_trust_vnic" {
  instance_id  = oci_core_instance.palo_alto_vm_2.id
  display_name = "trust_vnic_2"
  create_vnic_details {
    subnet_id              = oci_core_subnet.trust_subnet.id
    private_ip             = cidrhost(oci_core_subnet.trust_subnet.cidr_block, 3)
    skip_source_dest_check = true
  }
  depends_on = [oci_core_vnic_attachment.pa2_untrust_vnic]
}

resource "oci_core_vnic_attachment" "pa2_ha2_vnic" {
  instance_id  = oci_core_instance.palo_alto_vm_2.id
  display_name = "ha2_vnic_2"
  create_vnic_details {
    subnet_id  = oci_core_subnet.ha2_subnet.id
    private_ip = cidrhost(oci_core_subnet.ha2_subnet.cidr_block, 3)
  }
  depends_on = [oci_core_vnic_attachment.pa2_trust_vnic]
}

# --- FLOATING SECONDARY IPs ---

resource "oci_core_private_ip" "untrust_floating_ip" {
  vnic_id      = oci_core_vnic_attachment.pa1_untrust_vnic.vnic_id
  display_name = "untrust_floating_ip"
  hostname_label = "untrust-vip"
  ip_address   = cidrhost(oci_core_subnet.untrust_subnet.cidr_block, 100)
}

resource "oci_core_public_ip" "untrust_floating_public_ip" {
  compartment_id = var.compartment_id
  display_name   = "untrust_floating_public_ip"
  lifetime       = "RESERVED"
  private_ip_id  = oci_core_private_ip.untrust_floating_ip.id
}

resource "oci_core_private_ip" "trust_floating_ip" {
  vnic_id      = oci_core_vnic_attachment.pa1_trust_vnic.vnic_id
  display_name = "trust_floating_ip"
  hostname_label = "trust-vip"
  ip_address   = cidrhost(oci_core_subnet.trust_subnet.cidr_block, 100)
}

# --- COMPUTE (LINUX WORKER VM) ---

resource "oci_core_instance" "linux_vm" {
  availability_domain = local.ad_1
  compartment_id      = var.compartment_id
  display_name        = "linux-worker-vm"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.workload_subnet.id
    display_name     = "linux_vnic"
    assign_public_ip = true
    hostname_label   = "linuxworker"
    private_ip       = cidrhost(oci_core_subnet.workload_subnet.cidr_block, 254)
  }

  source_details {
    source_type = "image"
    source_id   = length(data.oci_core_images.linux_image.images) > 0 ? data.oci_core_images.linux_image.images[0].id : null
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(var.linux_user_data_raw)
  }

  depends_on = [
    oci_core_instance.palo_alto_vm_1,
    oci_core_instance.palo_alto_vm_2,
    oci_core_vnic_attachment.pa1_ha2_vnic,
    oci_core_vnic_attachment.pa2_ha2_vnic,
    oci_core_private_ip.trust_floating_ip
  ]

  lifecycle {
    precondition {
      condition     = length(data.oci_core_images.linux_image.images) > 0
      error_message = "The Oracle Linux 9.6 aarch64 image was not found. Please verify availability in your region."
    }
  }
}

# --- OUTPUTS ---

output "firewall_1_mgmt_ip" {
  value = oci_core_instance.palo_alto_vm_1.public_ip
}

output "firewall_2_mgmt_ip" {
  value = oci_core_instance.palo_alto_vm_2.public_ip
}

output "untrust_floating_public_ip" {
  value = oci_core_public_ip.untrust_floating_public_ip.ip_address
}

output "linux_vm_public_ip" {
  value = oci_core_instance.linux_vm.public_ip
}

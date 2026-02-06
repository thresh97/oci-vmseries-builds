tenancy_ocid        = "ocid1.tenancy.oc1..aaaaaaaaxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
compartment_id      = "ocid1.compartment.oc1..aaaaaaaaxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
region              = "us-phoenix-1"
oci_auth_method     = "InstancePrincipal"
ssh_public_key      = "ssh-rsa AAAAB3NzaC1yc2E...[REPLACE_WITH_YOUR_PUBLIC_KEY]..."
allowed_mgmt_cidrs  = ["0.0.0.0/32"] # Replace with your specific management IPs
panos_version       = "12.1.2"

vmseries_bootstrap_custom_1 = <<EOT
authcodes=YOUR_AUTH_CODE_HERE
panorama-server=cloud
plugin-op-commands=advance-routing:enable,set-cores:2
op-command-modes=jumbo-frame
vm-series-auto-registration-pin-id=00000000-0000-0000-0000-000000000000
vm-series-auto-registration-pin-value=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
dgname=oci_ha # SCM folder name in the SCM tenant
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
EOT

vmseries_bootstrap_custom_2 = <<EOT
authcodes=YOUR_AUTH_CODE_HERE
panorama-server=cloud
plugin-op-commands=advance-routing:enable,set-cores:2
op-command-modes=jumbo-frame
vm-series-auto-registration-pin-id=00000000-0000-0000-0000-000000000000
vm-series-auto-registration-pin-value=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
dgname=oci_ha # SCM folder name in the SCM tenant
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
EOT

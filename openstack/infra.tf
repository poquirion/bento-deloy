provider "openstack" {
}

data "openstack_images_image_v2" "image" {
  name = var.image
}


data "openstack_compute_flavor_v2" "proxy" {
  name = var.instances["proxy"]["type"]
}

data "openstack_compute_flavor_v2" "bento" {
  for_each = local.bento
  name = each.value.type
}


resource "openstack_compute_secgroup_v2" "secgroup_1" {
  name        = "${var.cluster_name}-secgroup"
  description = "Slurm+JupyterHub security group"

  rule {
    from_port   = -1
    to_port     = -1
    ip_protocol = "icmp"
    self        = true
  }

  rule {
    from_port   = 1
    to_port     = 65535
    ip_protocol = "tcp"
    self        = true
  }

  rule {
    from_port   = 1
    to_port     = 65535
    ip_protocol = "udp"
    self        = true
  }

  dynamic "rule" {
    for_each = var.firewall_rules
    content {
      from_port   = rule.value.from_port
      to_port     = rule.value.to_port
      ip_protocol = rule.value.ip_protocol
      cidr        = rule.value.cidr
    }
  }
}


resource "openstack_compute_keypair_v2" "keypair" {
  name       = "${var.cluster_name}-key"
  public_key = var.public_keys[0]
}

resource "openstack_networking_port_v2" "port_proxy" {
  count              = var.instances["proxy"]["count"]
  name               = format("%s-port-proxy%d", var.cluster_name, count.index + 1)
  network_id         = local.network.id
  security_group_ids = [openstack_compute_secgroup_v2.secgroup_1.id]
  fixed_ip {
    subnet_id = local.subnet.id
  }
}

resource "openstack_compute_instance_v2" "proxy" {
  count    = var.instances["proxy"]["count"]
  name     = format("%s-proxy%d", var.cluster_name, count.index + 1)
  image_id = var.root_disk_size > data.openstack_compute_flavor_v2.proxy.disk ? null : data.openstack_images_image_v2.image.id

  flavor_name     = var.instances["proxy"]["type"]
  key_pair        = openstack_compute_keypair_v2.keypair.name
  security_groups = [openstack_compute_secgroup_v2.secgroup_1.name]
  user_data       = data.template_cloudinit_config.proxy_config[count.index].rendered

  network {
    port = openstack_networking_port_v2.port_proxy[count.index].id
  }
  dynamic "network" {
    for_each = local.ext_networks
    content {
      access_network = network.value.access_network
      name           = network.value.name
    }
  }

  dynamic "block_device" {
    for_each = var.root_disk_size > data.openstack_compute_flavor_v2.proxy.disk ? [{volume_size = var.root_disk_size}] : []
    content {
      uuid                  = data.openstack_images_image_v2.image.id
      source_type           = "image"
      destination_type      = "volume"
      boot_index            = 0
      delete_on_termination = true
      volume_size           = block_device.value.volume_size
    }
  }

  lifecycle {
    ignore_changes = [
      image_id,
      block_device[0].uuid
    ]
  }
}


resource "openstack_networking_port_v2" "port_bento" {
  for_each           = local.bento
  name               = format("%s-port-%s", var.cluster_name, each.key)
  network_id         = local.network.id
  security_group_ids = [openstack_compute_secgroup_v2.secgroup_1.id]
  fixed_ip {
    subnet_id = local.subnet.id
  }
}

locals {
  bento_map = {
    for key in keys(local.bento):
      key => merge(
        {
          name      = format("%s", key)
          image_id  = data.openstack_images_image_v2.image.id,
          port      = openstack_networking_port_v2.port_bento[key].id,
          networks  = local.ext_networks,
          root_disk = var.root_disk_size > data.openstack_compute_flavor_v2.bento[key].disk ? [{volume_size = var.root_disk_size}] : []
          user_data = data.template_cloudinit_config.bento_config[key].rendered
        },
        local.bento[key]
    )
  }
}


resource "openstack_blockstorage_volume_v2" "data" {
  for_each = local.bento_map
  name        = format("%s-data",each.value["name"])
  description = format("%s /data", each.value["name"])
  size        = each.value["data_size"]
}


resource "openstack_compute_volume_attach_v2" "va_data" {
  for_each = local.bento_map
  instance_id = openstack_compute_instance_v2.bento[each.value["name"]].id
  volume_id   = openstack_blockstorage_volume_v2.data[each.value["name"]].id
}


resource "openstack_compute_instance_v2" "bento" {
  for_each = local.bento_map
  name     = each.value["name"]

  image_id = length(each.value["root_disk"]) == 0 ? each.value["image_id"] : null

  flavor_name     = each.value["type"]
  key_pair        = openstack_compute_keypair_v2.keypair.name
  security_groups = [openstack_compute_secgroup_v2.secgroup_1.name]
  user_data       = each.value["user_data"]

  network {
    port = each.value["port"]
  }
  dynamic "network" {
    for_each = each.value["networks"]
    content {
      access_network = network.value.access_network
      name           = network.value.name
    }
  }

  dynamic "block_device" {
    for_each = each.value["root_disk"]
    content {
      uuid                  = each.value["image_id"]
      source_type           = "image"
      destination_type      = "volume"
      boot_index            = 0
      delete_on_termination = true
      volume_size           = block_device.value.volume_size
    }
  }

  lifecycle {
    ignore_changes = [
      image_id,
      block_device[0].uuid
    ]
  }
}


locals {
  data_dev        = [for vol in openstack_blockstorage_volume_v2.data:    "/dev/disk/by-id/*${substr(vol.id, 0, 20)}"]
  puppetmaster_ip = openstack_networking_port_v2.port_proxy[0].all_fixed_ips[0]
}

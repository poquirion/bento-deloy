resource "random_string" "puppetmaster_password" {
  length  = 32
  special = false
}

resource "random_string" "freeipa_passwd" {
  length  = 16
  special = false
}

resource "random_pet" "guest_passwd" {
  count     = var.guest_passwd != "" ? 0 : 1
  length    = 4
  separator = "."
}

resource "random_uuid" "consul_token" { }

data "http" "hieradata_template" {
  url = "${replace(var.puppetenv_git, ".git", "")}/raw/${var.puppetenv_rev}/data/terraform_data.yaml.tmpl"
}

data "template_file" "hieradata" {
  template = data.http.hieradata_template.body

  vars = {
    sudoer_username = var.sudoer_username
    freeipa_passwd  = random_string.freeipa_passwd.result
    cluster_name    = var.cluster_name
    guest_passwd    = var.guest_passwd != "" ? var.guest_passwd : random_pet.guest_passwd[0].id
    consul_token    = random_uuid.consul_token.result
  }
}


resource "tls_private_key" "login_rsa" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

data "template_cloudinit_config" "proxy_config" {
  count = var.instances["proxy"]["count"]

  part {
    filename     = "ssh_keys.yaml"
    merge_type   = "list(append)+dict(recurse_array)+str()"
    content_type = "text/cloud-config"
    content      = <<EOF
runcmd:
  - chmod 644 /etc/ssh/ssh_host_rsa_key.pub
  - chgrp ssh_keys /etc/ssh/ssh_host_rsa_key.pub
ssh_keys:
  rsa_private: |
    ${indent(4, tls_private_key.login_rsa.private_key_pem)}
  rsa_public: |
    ${tls_private_key.login_rsa.public_key_openssh}
EOF
  }
  part {
    filename     = "proxy.yaml"
    merge_type   = "list(append)+dict(recurse_array)+str()"
    content_type = "text/cloud-config"
    content      = templatefile(
      "${path.module}/cloud-init/proxy.yaml",
      {
        puppetenv_git         = replace(replace(var.puppetenv_git, ".git", ""), "//*$/", ".git"),
        puppetenv_rev         = var.puppetenv_rev,
        puppetmaster_ip       = local.puppetmaster_ip,
        puppetmaster_password = random_string.puppetmaster_password.result,
        hieradata             = data.template_file.hieradata.rendered,
        user_hieradata        = var.hieradata,
        node_name             = format("proxy_%d", count.index + 1),
        sudoer_username       = var.sudoer_username,
        ssh_authorized_keys   = var.public_keys,
      }
    )
  }
}

locals {
  bento = {
    for item in flatten([
      for bento in var.instances["bento"]: [
        for j in range(bento.count): {
          (
            lookup(bento, "name", "") != "" ?
            format("%s", lookup(bento, "name", "")) :
            format("bento%d", j+1)
          ) = {
            for key in setsubtract(keys(bento), ["name", "count"]):
              key => bento[key]
          }
        }
      ]
    ]):
    keys(item)[0] => values(item)[0]
  }
}

data "template_cloudinit_config" "bento_config" {
  for_each = local.bento
  part {
    filename     = "bento.yaml"
    merge_type   = "list(append)+dict(recurse_array)+str()"
    content_type = "text/cloud-config"
    content      = templatefile(
      "${path.module}/cloud-init/bento.yaml",
      {
        node_name             = each.key,
        manager_user          = each.value["managername"],
        sudoer_username       = var.sudoer_username,
        ssh_authorized_keys   = var.public_keys,
        puppetmaster_ip       = local.puppetmaster_ip,
        puppetmaster_password = random_string.puppetmaster_password.result,
      }
    )
  }
}

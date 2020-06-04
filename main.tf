terraform {
  required_version = ">= 0.12.21"
}

module "openstack" {
  source = "./openstack"

  cluster_name = "obentoyasan"
  image        = "CentOS-7-x64-2020-03"
  nb_users     = 1

  instances = {

      proxy = { type = "p2-3gb", count = 1 },
      bento= [
        {type = "p2-3gb", name = "ichange", managername="ichange",
          count = 1, data_size = 1000 },
        {type = "p2-3gb", name = "signature", managername="signature",
          count = 1, data_size = 1000 }
      ]

  }


  sudoer_username = "sake"

  public_keys = [file("~/.ssh/id_rsa.pub")]

  # Shared password, randomly chosen if blank
  guest_passwd = "truite"

  # OpenStack specific
  os_floating_ips = []
}

output "sudoer_username" {
  value = module.openstack.sudoer_username
}

output "guest_usernames" {
  value = module.openstack.guest_usernames
}

output "guest_passwd" {
  value = module.openstack.guest_passwd
}

output "public_ip" {
  value = module.openstack.ip
}

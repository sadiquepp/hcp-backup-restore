output "instances" {
  description = "One entry per metal host."
  value = [
    for i, inst in aws_instance.metal : {
      name       = inst.tags["Name"]
      public_ip  = inst.public_ip
      private_ip = inst.private_ip
      ssh        = "ssh -i ${var.ssh_private_key_path} ec2-user@${inst.public_ip}"
    }
  ]
}

output "public_ips" {
  description = "Just the addresses, for scripting."
  value       = aws_instance.metal[*].public_ip
}

# The one screen someone needs after `terraform apply`. Everything that is not
# ssh is reached by forwarding a port over ssh, because the security group
# opens nothing else.
output "next_steps" {
  description = "What to do once the instances are up."
  value       = <<-EOT

    ${var.instance_count} x ${var.instance_type} in ${var.region} (${local.az})

    %{for i, inst in aws_instance.metal~}
      ${inst.tags["Name"]}  ${inst.public_ip}
          ssh -i ${var.ssh_private_key_path} ec2-user@${inst.public_ip}
    %{endfor~}

    1. STAGE THE RHEL KVM IMAGE. This is the one thing the automation cannot
       do for you - it needs your Red Hat login. Download
       rhel-9.8-x86_64-kvm.qcow2 from access.redhat.com/downloads and copy it
       to each host:

    %{for i, inst in aws_instance.metal~}
          scp -i ${var.ssh_private_key_path} rhel-9.8-x86_64-kvm.qcow2 \
              ec2-user@${inst.public_ip}:/tmp/
          ssh -i ${var.ssh_private_key_path} ec2-user@${inst.public_ip} \
              'sudo mv /tmp/rhel-9.8-x86_64-kvm.qcow2 ${var.base_image_dir}/'
    %{endfor~}

    2. PUT YOUR CREDENTIALS IN vault.yaml on each host:

          sudo -i
          cd /root/hcp-backup-restore
          ansible-vault create vault.yaml      # pull_secret, org_id,
                                               # activation_key, ssh_key,
                                               # dns_forwarders
          echo '<vault password>' > ~/.vault_pass && chmod 600 ~/.vault_pass

    3. BUILD, under tmux - it takes hours and an ssh drop kills it:

          tmux new -s lab
          cd /root/hcp-backup-restore/udn-bgp-evpn
          ./build-lab.sh --evpn          # or --vrflite / --shared

    VNC (if vnc_enabled) is on loopback only. Tunnel to it:

          ssh -i ${var.ssh_private_key_path} -L 5999:localhost:5999 \
              ec2-user@${aws_instance.metal[0].public_ip}
          # then point a viewer at localhost:99
          # password: sudo cat /root/.vnc-credentials

    The security group opens ssh and nothing else. Reach the cluster API and
    consoles the same way, by forwarding ports over that connection.
  EOT
}

# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  # Every Vagrant virtual environment requires a box to build off of.
  config.vm.box = "bento/centos-7.1"
  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__args: ["-avz", "--delete"],
    rsync__exclude: [".git/", ".stack-work/"]

  config.vm.provider :aws do |aws, override|
    override.ssh.private_key_path = 'ci/ci.pem'
    override.ssh.username = 'centos'
    override.vm.box = 'dummy'
    override.vm.box_url = "https://github.com/mitchellh/vagrant-aws/raw/master/dummy.box"

    aws.access_key_id = ENV['AWS_ACCESS_KEY_ID']
    aws.secret_access_key = ENV['AWS_SECRET_ACCESS_KEY']
    aws.security_groups = ["continuous-integration"]
    aws.instance_type = "c4.xlarge"
    aws.keypair_name = "ci"
    aws.ami = "ami-2d377447"
    aws.block_device_mapping =
      [{ 'DeviceName' => '/dev/xvda',
         'Ebs.VolumeSize' => 20,
         'Ebs.VolumeType' => 'gp2',
         'Ebs.DeleteOnTermination' => 'true'
       }]
    aws.region = "us-east-1"
    aws.terminate_on_shutdown = true
    aws.user_data = "#!/bin/bash\nsed -i -e 's/^Defaults.*requiretty/# Defaults requiretty/g' /etc/sudoers"
  end

end

#!/bin/bash

set -euo pipefail

# Get the master node IP from the yml file generated by vagrant
contiv_master=$(grep -B 3 master cluster/.cfg.yml | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}" | xargs)
node_os=${CONTIV_NODE_OS:-"centos"}
# Default user is vagrant for non-ubuntu and ubuntu for ubuntu boxes.
if [ "$node_os" == "ubuntu" ]; then
	def_user="ubuntu"
	def_key="$HOME/.ssh/id_rsa"
else
	def_user="vagrant"
	def_key=""
fi
user=${CONTIV_SSH_USER:-"$def_user"}

# If BUILD_VERSION is not defined, we use a local dev build, that must have been created with make release
install_version="contiv-${BUILD_VERSION:-devbuild}"
default_net_cidr="${DEFAULT_NET:-20.1.1.0/24}"
default_net_gw="${DEFAULT_NET:-20.1.1.1}"

# For local builds, copy the build binaries to the vagrant node, using the vagrant ssh-key
if [ -f "release/${install_version}.tgz" ]; then
	pushd cluster
	ssh_key=${CONTIV_SSH_KEY:-"$def_key"}
	if [ "$ssh_key" == "" ]; then
		ssh_key=$(CONTIV_KUBEADM=1 vagrant ssh-config contiv-node1 | grep IdentityFile | awk '{print $2}' | xargs)
	fi
	popd
	dest_path=${CONTIV_TARGET:-"/home/$user"}
	ssh_opts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

	# Copy the installation folder
	scp $ssh_opts -i $ssh_key release/${install_version}.tgz $user@$contiv_master:$dest_path
	curl_cmd="echo 'Devbuild'"
else
	# github redirects you to a signed AWS URL, so we need to follow redirects with -L
	curl_cmd="curl -L -O https://github.com/contiv/install/releases/download/${BUILD_VERSION}/${install_version}.tgz"
fi
# Extract the install bundle and launch the installer
set +e # read returns 1 when it succeeds
read -r -d '' COMMANDS <<-EOF
    sudo rm -rf ${install_version} && \\
    ${curl_cmd} && tar oxf ${install_version}.tgz && \\
    cd ${install_version} && \\
    sudo ./install/k8s/install.sh -n ${contiv_master}
EOF
set -e

cd cluster
CONTIV_KUBEADM=1 vagrant ssh contiv-node1 -- "$COMMANDS"

set +e
read -r -d '' SETUP_DEFAULT_NET <<-EOF
    cd ${install_version} && \\
    netctl net create -s ${default_net_cidr} -g ${default_net_gw} default-net
EOF
set -e

echo "*****************"
# Wait for CONTIV to start for up to 10 minutes
sleep 10
for i in {0..20}; do
	response=$(curl -k -s -H "Content-Type: application/json" -X POST -d '{"username": "admin", "password": "admin"}' https://$contiv_master:10000/api/v1/auth_proxy/login/ || true)
	if [[ $response == *"token"* ]]; then
		echo "Install SUCCESS"
		echo ""
		cat <<EOF
  NOTE: Because the Contiv Admin Console is using a self-signed certificate for this demo,
  you will see a security warning when the page loads.  You can safely dismiss it.
  
  You can access the Contiv master node with:
    cd cluster && CONTIV_KUBEADM=1 vagrant ssh contiv-node1

EOF
		if [ "$install_version" != "contiv-devbuild" ]; then
			CONTIV_KUBEADM=1 vagrant ssh contiv-node1 -- "${SETUP_DEFAULT_NET}"
		fi
		exit 0
	else
		echo "$i. Retry login to Contiv"
		sleep 30
	fi
done
echo "Install FAILED"
exit 1

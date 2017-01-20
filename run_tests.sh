#!/bin/bash -ex
# Copyright 2015 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

export PUPPET_VERSION=${PUPPET_VERSION:-3}
export SCENARIO=${SCENARIO:-scenario001}
export MANAGE_PUPPET_MODULES=${MANAGE_PUPPET_MODULES:-true}
export MANAGE_REPOS=${MANAGE_REPOS:-true}
export SCRIPT_DIR=$(cd `dirname $0` && pwd -P)
export HIERA_CONFIG=${HIERA_CONFIG:-${SCRIPT_DIR}/hiera/hiera.yaml}
export MANAGE_HIERA=${MANAGE_HIERA:-true}
export PUPPET_ARGS="${PUPPET_ARGS} --detailed-exitcodes --color=false --test --trace --hiera_config ${HIERA_CONFIG}"
# Tempest 12.2.0 is the latest releast that supports Mitaka.
# http://docs.openstack.org/releasenotes/tempest/v12.0.0.html
export TEMPEST_VERSION=${TEMPEST_VERSION:-12.2.0}

# NOTE(pabelanger): Setup facter to know about AFS mirror.
if [ -f /etc/nodepool/provider ]; then
    source /etc/nodepool/provider
    NODEPOOL_MIRROR_HOST=${NODEPOOL_MIRROR_HOST:-mirror.$NODEPOOL_REGION.$NODEPOOL_CLOUD.openstack.org}
    NODEPOOL_MIRROR_HOST=$(echo $NODEPOOL_MIRROR_HOST|tr '[:upper:]' '[:lower:]')
    CENTOS_MIRROR_HOST=${NODEPOOL_MIRROR_HOST}
    UBUNTU_MIRROR_HOST="${NODEPOOL_MIRROR_HOST}/ubuntu-cloud-archive"
else
    CENTOS_MIRROR_HOST='mirror.centos.org'
    UBUNTU_MIRROR_HOST='ubuntu-cloud.archive.canonical.com/ubuntu'
fi
export FACTER_centos_mirror_host="http://${CENTOS_MIRROR_HOST}"
export FACTER_ubuntu_mirror_host="http://${UBUNTU_MIRROR_HOST}"

if [ $PUPPET_VERSION == 4 ]; then
  export PATH=${PATH}:/opt/puppetlabs/bin
  export PUPPET_RELEASE_FILE=puppetlabs-release-pc1
  export PUPPET_BASE_PATH=/etc/puppetlabs/code
  export PUPPET_PKG=puppet-agent
else
  export PUPPET_RELEASE_FILE=puppetlabs-release
  export PUPPET_BASE_PATH=/etc/puppet
  export PUPPET_PKG=puppet
fi

source ${SCRIPT_DIR}/functions

if [ ! -f fixtures/${SCENARIO}.pp ]; then
    echo "fixtures/${SCENARIO}.pp file does not exist. Please define a valid scenario."
    exit 1
fi

if [ $(id -u) != 0 ]; then
  # preserve environment so we can have ZUUL_* params
  SUDO='sudo -E'
fi

git clone git://git.openstack.org/openstack/tempest /tmp/openstack/tempest
pushd /tmp/openstack/tempest
git reset --hard $TEMPEST_VERSION
popd

$SUDO rm -f /tmp/openstack/tempest/cirros-0.3.4-x86_64-disk.img
# NOTE(pabelanger): We cache cirros images on our jenkins slaves, check if it
# exists.
if [ -f ~/cache/files/cirros-0.3.4-x86_64-disk.img ]; then
    # Create a symlink for tempest.
    ln -s ~/cache/files/cirros-0.3.4-x86_64-disk.img /tmp/openstack/tempest
else
    wget http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img -P /tmp/openstack/tempest
fi

function run_puppet() {
    local manifest=$1
    $SUDO puppet apply $PUPPET_ARGS fixtures/${manifest}.pp
    local res=$?

    return $res
}

function catch_selinux_alerts() {
    if is_fedora; then
        $SUDO sealert -a /var/log/audit/audit.log
        if $SUDO grep -iq 'type=AVC' /var/log/audit/audit.log; then
            echo "AVC detected in /var/log/audit/audit.log"
            # TODO: figure why latest rabbitmq deployed with SSL tries to write in SSL pem file.
            # https://bugzilla.redhat.com/show_bug.cgi?id=1341738
            if $SUDO grep -iqE 'denied.*system_r:rabbitmq_t' /var/log/audit/audit.log; then
                echo "non-critical RabbitMQ AVC, ignoring it now."
            else
                echo "Please file a bug on https://bugzilla.redhat.com/enter_bug.cgi?product=Red%20Hat%20OpenStack&component=openstack-selinux showing sealert output."
            fi
        else
            echo 'No AVC detected in /var/log/audit/audit.log'
        fi
    fi
}

if uses_debs; then
    if dpkg -l $PUPPET_RELEASE_FILE >/dev/null 2>&1; then
        $SUDO apt-get purge -y $PUPPET_RELEASE_FILE
    fi
    $SUDO rm -f /tmp/puppet.deb

    wget http://apt.puppetlabs.com/${PUPPET_RELEASE_FILE}-trusty.deb -O /tmp/puppet.deb
    $SUDO dpkg -i /tmp/puppet.deb
    $SUDO apt-get update
    $SUDO apt-get install -y dstat ${PUPPET_PKG}
elif is_fedora; then
    if rpm --quiet -q $PUPPET_RELEASE_FILE; then
        $SUDO rpm -e $PUPPET_RELEASE_FILE
    fi
    # EPEL does not work fine with RDO, we need to make sure EPEL is really disabled
    if rpm --quiet -q epel-release; then
        $SUDO rpm -e epel-release
    fi
    $SUDO rm -f /tmp/puppet.rpm

    wget  http://yum.puppetlabs.com/${PUPPET_RELEASE_FILE}-el-7.noarch.rpm -O /tmp/puppet.rpm
    $SUDO rpm -ivh /tmp/puppet.rpm
    $SUDO yum install -y dstat ${PUPPET_PKG} setools setroubleshoot audit
    $SUDO service auditd start

    # SElinux in permissive mode so later we can catch alerts
    $SUDO setenforce 0
fi

if [ "${MANAGE_HIERA}" = true ]; then
  configure_hiera
fi

# use dstat to monitor system activity during integration testing
if type "dstat" 2>/dev/null; then
  $SUDO dstat -tcmndrylpg --top-cpu-adv --top-io-adv --nocolor | $SUDO tee --append /var/log/dstat.log > /dev/null &
fi

if [ "${MANAGE_PUPPET_MODULES}" = true ]; then
    $SUDO ./install_modules.sh
fi

# Run puppet and assert something changes.
set +e
if [ "${MANAGE_REPOS}" = true ]; then
  $SUDO puppet apply $PUPPET_ARGS -e "include ::openstack_integration::repos"
  if is_fedora; then
    $SUDO yum update -y
    if [ $? -ne 0 ]; then
        exit 1
    fi
  fi
fi
run_puppet $SCENARIO
RESULT=$?
set -e
if [ $RESULT -ne 2 ]; then
    catch_selinux_alerts
    exit 1
fi

# Run puppet a second time and assert nothing changes.
set +e
run_puppet $SCENARIO
RESULT=$?
set -e
if [ $RESULT -ne 0 ]; then
    catch_selinux_alerts
    exit 1
fi

set +e
# Select what to test:
# Smoke suite
TESTS="smoke"

# Horizon
TESTS="${TESTS} dashbboard"

# Aodh
TESTS="${TESTS} TelemetryAlarming"

# Ironic
# Note: running all Ironic tests under SSL is not working
# https://bugs.launchpad.net/ironic/+bug/1554237
TESTS="${TESTS} api.baremetal.admin.test_drivers"

cd /tmp/openstack/tempest; tox -eall -- --concurrency=2 $TESTS
RESULT=$?
set -e
/tmp/openstack/tempest/.tox/tempest/bin/testr last --subunit > /tmp/openstack/tempest/testrepository.subunit
catch_selinux_alerts
exit $RESULT

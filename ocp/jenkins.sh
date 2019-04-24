#!/bin/bash

PROJECT=$1
GITHUBORG=$2
if [ $# -ne 2 ]
then
  echo "project should be \$1, Gitgub organization \$2"
  exit 100
fi
## Use latest Jenkins container to fix credential-sync-plugin
oc import-image jenkins-2-rhel7 --from=registry.access.redhat.com/openshift3/jenkins-2-rhel7:v3.11.82-4 --confirm

## Customize the the image imported above with all the build tools we need
oc new-build -D $'FROM jenkins-2-rhel7:latest\n
      USER root\n
      RUN rpm --import https://yum.puppetlabs.com/RPM-GPG-KEY-puppet && yum-config-manager --add-repo https://yum.puppet.com/puppet5/el/7/x86_64/ && yum -y install puppet-agent && yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm && yum install -y python-setuptools rubygem-puppet-lint gcc zlib-devel gcc-c++ && yum install -y http://mirror.centos.org/centos/7/updates/x86_64/Packages/ruby-devel-2.0.0.648-34.el7_6.x86_64.rpm && yum clean all && easy_install pip && pip install yamllint\n
      USER root\n
      RUN gem install bundler -v '1.17.3' --source 'https://rubygems.org/'  &&  gem install json -v '1.8.6' --source 'https://rubygems.org/'\n
      USER jenkins\n\
      WORKDIR /var/lib/jenkins' --name=puppet-jenkins

## Define Jenkins customization in config map
oc create configmap jenkins-configuration \
    --from-literal=casc_jenkins.yaml="`cat config/jenkins_configuration/casc_jenkins.yaml |sed -e "s/\\${PROJECT}/${PROJECT}/g"`" \
    --from-literal=config.groovy="`cat config/jenkins_configuration/config.groovy |sed -e "s/\\${PROJECT}/${PROJECT}/g" -e "s/\\${GITHUBORG}/${GITHUBORG}/g"`" \
    --from-file=yamllint.conf=config/jenkins_configuration/yamllint.conf

oc create secret generic jenkins-ci-github-key \
    --from-file=ssh-privatekey=config/jenkins_configuration/.ssh/id_rsa \
    --type=kubernetes.io/ssh-auth

## Set of additional plugins to install. Github branch source plugin is installed by default
JENKINS_PLUGINS=`cat config/jenkins_configuration/jenkins.plugins`

## Deploy the Openshift built-in Jenkins template with the newly build image.
oc process openshift//jenkins-ephemeral -p JENKINS_IMAGE_STREAM_TAG=puppet-jenkins:latest NAMESPACE=${PROJECT} | oc create -f -

## Pause rollouts to proceed with additional configuration
oc rollout pause dc jenkins

## Up memory & cpu to get a responsive Jenkins
oc patch dc jenkins -p '{"spec":{"template":{"spec":{"containers":[{"name":"jenkins","resources":{"requests":{"cpu":"1","memory":"1Gi"},"limits":{"cpu":"1","memory":"1Gi"}}}]}}}}'
oc set env dc/jenkins MEMORY_LIMIT=1Gi

oc set env dc/jenkins DISABLE_ADMINISTRATIVE_MONITORS=true
oc set env dc/jenkins INSTALL_PLUGINS="${JENKINS_PLUGINS}"
oc set env dc/jenkins CASC_JENKINS_CONFIG="/var/lib/jenkins/init.groovy.d/casc_jenkins.yaml"
oc set volumes dc/jenkins --add --configmap-name=jenkins-configuration --mount-path='/var/lib/jenkins/init.groovy.d/' --name "jenkins-config"
oc set volumes dc/jenkins --add --configmap-name=jenkins-configuration --mount-path='/var/lib/jenkins/.config/yamllint' --name "yamllint-config"
oc set volumes dc/jenkins --add --secret-name=jenkins-ci-github-key --mount-path='/var/lib/jenkins/.ssh/id_rsa' --name "jenkins-ci-github-key" --read-only=true

oc patch dc jenkins -p '{"spec":{"template":{"spec":{"volumes":[{"configMap":{"items":[{"key":"yamllint.conf","path":"config"}],"name":"jenkins-configuration"},"name":"yamllint-config"}]}}}}'
oc patch dc jenkins -p '{"spec":{"template":{"spec":{"volumes":[{"secret":{"items":[{"key":"ssh-privatekey","path":"id_rsa"}],"defaultMode": 420,"secretName":"jenkins-ci-github-key"},"name":"jenkins-ci-github-key"}]}}}}'

oc rollout resume dc jenkins

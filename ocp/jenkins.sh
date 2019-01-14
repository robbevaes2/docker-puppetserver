#!/bin/bash


## Use latest Jenkins container to fix credential-sync-plugin
oc import-image jenkins-2-rhel7 --from=registry.access.redhat.com/openshift3/jenkins-2-rhel7:v3.11.51-2 --confirm

## Customize the the image imported above with all the build tools we need
oc new-build -D $'FROM jenkins-2-rhel7:latest \n
      USER root\nRUN yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm && yum install -y python-setuptools puppet rubygem-puppet-lint && yum clean all && easy_install pip && pip install yamllint\n
      USER 1001' --name=puppet-jenkins

## Define Jenkins customization in config map
oc create configmap jenkins-configuration --from-file=casc_jenkins.yaml=../jenkins_configuration/casc_jenkins.yaml --from-file=config.groovy=../jenkins_configuration/config.groovy

## Set of additional plugins to install. Github branch source plugin is installed by default
JENKINS_PLUGINS="configuration-as-code"

## Deploy the Openshift built-in Jenkins template with the newly build image.
oc process openshift//jenkins-ephemeral -p JENKINS_IMAGE_STREAM_TAG=puppet-jenkins:latest NAMESPACE=ci00053160-puppetserver | oc create -f -

## Pause rollouts to proceed with additional configuration
oc rollout pause dc jenkins

## Up memory & cpu to get a responsive Jenkins
oc patch dc jenkins -p '{"spec":{"template":{"spec":{"containers":[{"name":"jenkins","resources":{"requests":{"cpu":"1","memory":"1Gi"},"limits":{"cpu":"1","memory":"1Gi"}}}]}}}}'
oc set env dc/jenkins MEMORY_LIMIT=1Gi

oc set env dc/jenkins DISABLE_ADMINISTRATIVE_MONITORS=true
oc set env dc/jenkins INSTALL_PLUGINS="${JENKINS_PLUGINS}"
oc set env dc/jenkins CASC_JENKINS_CONFIG="/var/lib/jenkins/init.groovy.d/casc_jenkins.yaml"
oc set volumes dc/jenkins --add --configmap-name=jenkins-configuration --mount-path='/var/lib/jenkins/init.groovy.d/'

oc rollout resume dc jenkins
oc expose svc/jenkins
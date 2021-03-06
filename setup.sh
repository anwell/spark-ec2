#!/bin/bash

# Generate id_rsa.pub
ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub
chmod 600 ~/.ssh/id_rsa.pub

# Load the cluster variables set by the deploy script
source ec2-variables.sh

# Make sure we are in the spark-ec2 directory
cd /home/$SSH_USER/spark-ec2

# Load the environment variables specific to this AMI
source /home/$SSH_USER/.bash_profile

# Set hostname based on EC2 private DNS name, so that it is set correctly
# even if the instance is restarted with a different private DNS name
PRIVATE_DNS=`wget -q -O - http://169.254.169.254/latest/meta-data/local-ipv4`
PUBLIC_DNS=`wget -q -O - http://instance-data.ec2.internal/latest/meta-data/hostname`
hostname $PRIVATE_DNS
echo $PRIVATE_DNS > /etc/hostname
export HOSTNAME=$PRIVATE_DNS  # Fix the bash built-in hostname variable too

echo "Setting up Spark on `hostname`..."

# Set up the masters, slaves, etc files based on cluster env variables
echo "$MESOS_MASTERS" > masters
echo "$MESOS_SLAVES" > slaves

# TODO(shivaram): Clean this up after docs have been updated ?
# This ensures /home/$SSH_USER/mesos-ec2/copy-dir still works
mkdir -p /home/$SSH_USER/mesos-ec2
cp -f slaves /home/$SSH_USER/mesos-ec2/
cp -f masters /home/$SSH_USER/mesos-ec2/

MASTERS=`cat masters`
NUM_MASTERS=`cat masters | wc -l`
OTHER_MASTERS=`cat masters | sed '1d'`
SLAVES=`cat slaves`
SSH_OPTS="-o StrictHostKeyChecking=no"

if [[ "x$JAVA_HOME" == "x" ]] ; then
    echo "Expected JAVA_HOME to be set in .bash_profile!"
    exit 1
fi

if [[ "x$SCALA_HOME" == "x" ]] ; then
    echo "Expected SCALA_HOME to be set in .bash_profile!"
    exit 1
fi

if [[ `tty` == "not a tty" ]] ; then
    echo "Expecting a tty or pty! (use the ssh -t option)."
    exit 1
fi

echo "Setting executable permissions on scripts..."
find . -regex "^.+.\(sh\|py\)" | xargs chmod a+x

echo "Running setup-slave on master to mount filesystems, etc..."
source ./setup-slave.sh

echo "SSH'ing to master machine(s) to approve key(s)..."
for master in $MASTERS; do
  echo $master
  sudo -u $SSH_USER ssh $SSH_OPTS $master echo -n &
  sleep 0.3
done
sudo -u $SSH_USER ssh $SSH_OPTS localhost echo -n &
sudo -u $SSH_USER ssh $SSH_OPTS `hostname` echo -n &
wait

# Try to SSH to each cluster node to approve their key. Since some nodes may
# be slow in starting, we retry failed slaves up to 3 times.
TODO="$SLAVES $OTHER_MASTERS" # List of nodes to try (initially all)
TRIES="0"                          # Number of times we've tried so far
echo "SSH'ing to other cluster nodes to approve keys..."
while [ "e$TODO" != "e" ] && [ $TRIES -lt 4 ] ; do
  NEW_TODO=
  for slave in $TODO; do
    echo $slave
    sudo -u $SSH_USER ssh $SSH_OPTS $slave echo -n
    if [ $? != 0 ] ; then
        NEW_TODO="$NEW_TODO $slave"
    fi
  done
  TRIES=$[$TRIES + 1]
  if [ "e$NEW_TODO" != "e" ] && [ $TRIES -lt 4 ] ; then
      sleep 15
      TODO="$NEW_TODO"
      echo "Re-attempting SSH to cluster nodes to approve keys..."
  else
      break;
  fi
done

echo "RSYNC'ing /home/$SSH_USER/spark-ec2 to other cluster nodes..."
for node in $SLAVES $OTHER_MASTERS; do
  echo $node
  sudo -u $SSH_USER rsync -e "ssh $SSH_OPTS" -az /home/$SSH_USER/spark-ec2 $SSH_USER@$node:/home/$SSH_USER &
  scp $SSH_OPTS ~/.ssh/id_rsa $SSH_USER@$node:.ssh &
  sleep 0.3
done
# wait

# NOTE: We need to rsync spark-ec2 before we can run setup-slave.sh
# on other cluster nodes
echo "Running slave setup script on other cluster nodes..."
for node in $SLAVES $OTHER_MASTERS; do
  echo $node
  sudo -u jpluser ssh -t -t $SSH_OPTS $node "cd spark-ec2; sudo ./setup-slave.sh" #& sleep 0.3
done
# wait

# Set environment variables required by templates
# TODO: Make this general by using a init.sh per module ?
./mesos/compute_cluster_url.py > ./cluster-url
export MESOS_CLUSTER_URL=`cat ./cluster-url`
# TODO(shivaram): Clean this up after docs have been updated ?
cp -f cluster-url /home/$SSH_USER/mesos-ec2/

# Install / Init module before templates if required
for module in $MODULES; do
  echo "Initializing $module"
  if [[ -e $module/init.sh ]]; then
    source $module/init.sh
  fi
done

# Deploy templates
# TODO: Move configuring templates to a per-module ?
echo "Creating local config files..."
./deploy_templates.py

# Copy spark conf by default
echo "Deploying Spark config files..."
chmod u+x /home/$SSH_USER/spark/conf/spark-env.sh
/home/$SSH_USER/spark-ec2/copy-dir /home/$SSH_USER/spark/conf

# Setup each module
for module in $MODULES; do
  echo "Setting up $module"
  source ./$module/setup.sh
  sleep 1
done

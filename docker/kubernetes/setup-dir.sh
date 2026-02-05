#/bin/bash
sudo mkdir -p /srv/nfs/k8s-storage
sudo mkdir -p /srv/etcd/data
sudo chown -R 1001:1001 /srv/etcd/data
sudo chmod -R 700 /srv/etcd/data
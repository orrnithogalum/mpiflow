#!/bin/bash
# node_setup.sh -- configure une VM Ubuntu 24.04 du mini-cluster Slurm (Mission 3)
#
#   sudo bash node_setup.sh controller <nœud-connexion> <nœud-calcul>
#   sudo bash node_setup.sh compute    <nœud-connexion> <nœud-calcul>
#
# Lancé par « cluster/gcp.sh setup » : d'abord le contrôleur, puis le nœud de calcul.
# La clé munge commune aux deux nœuds est attendue dans /tmp/munge.key.
#
#   hpc-login   : slurmctld, slurmdbd + MariaDB (sacct), slurmd, serveur NFS de /shared,
#                 Spack (et le runner GitHub, installé par runner_setup.sh)
#   hpc-compute : slurmd, client NFS
#
# Le script est idempotent : il peut être relancé après une erreur.
set -euo pipefail
ROLE=${1:?controller ou compute}
CTL=${2:?nom du nœud de connexion}
NODE=${3:?nom du nœud de calcul}
SHARED=/shared
CI_UID=3000                      # même UID sur les deux nœuds (NFS, Slurm)
export DEBIAN_FRONTEND=noninteractive
say() { echo "== [$(hostname -s)] $*"; }

# (re)démarre un service ; sans systemd (conteneur de test), lance le démon directement
svc() {
    if [ -d /run/systemd/system ]; then
        systemctl enable -q "$1" && systemctl restart "$1"
        return
    fi
    stop() { pkill -x "$1" || true; for _ in $(seq 40); do pgrep -x "$1" > /dev/null || return 0; sleep 0.5; done; }
    case "$1" in
        munge)     stop munged; install -d -o munge -g munge /run/munge
                   runuser -u munge -- /usr/sbin/munged ;;
        mariadb)   pgrep -x mariadbd > /dev/null || { install -d -o mysql -g mysql /run/mysqld
                   (mysqld_safe > /dev/null 2>&1 &); sleep 5; } ;;
        slurmdbd)  stop slurmdbd; install -d -o slurm -g slurm /run/slurmdbd
                   runuser -u slurm -- /usr/sbin/slurmdbd ;;
        slurmctld) stop slurmctld; install -d -o slurm -g slurm /run/slurmctld
                   runuser -u slurm -- /usr/sbin/slurmctld ;;
        slurmd)    stop slurmd; install -d /run/slurm; /usr/sbin/slurmd ;;
        *)         say "service $1 ignoré (pas de systemd)" ;;
    esac
}

# --- 1. Utilisateur « ci » (runner, jobs Slurm), UID fixe ------------------------------
# Le compte qui soumet les jobs doit exister avec le même UID sur tous les nœuds : slurmd
# lance les tâches sous cet UID, et NFS compare des UID, pas des noms.
getent group ci >/dev/null || groupadd -g "$CI_UID" ci
id ci >/dev/null 2>&1 || useradd -u "$CI_UID" -g ci -d "$SHARED/ci" -M -s /bin/bash ci

# --- 2. Paquets -------------------------------------------------------------------------
# libpmix2t64 : le greffon mpi/pmix de Slurm charge libpmix à l'exécution (dlopen) ;
# sans ce paquet, « srun --mpi=pmix » échoue alors qu'aucune dépendance ne manque.
COMMON="munge slurmd slurm-client libpmix2t64 python3 curl ca-certificates"
if [ "$ROLE" = controller ]; then
    # outils requis par Spack (compilateurs système : gcc, g++, gfortran 13.3)
    PKGS="$COMMON slurmctld slurmdbd mariadb-server nfs-kernel-server build-essential gfortran
          git unzip bzip2 xz-utils zstd file patch gnupg python3-venv"
else
    PKGS="$COMMON nfs-common"
fi
say "installation des paquets ($ROLE)"
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq $PKGS > /dev/null

# --- 3. munge : même clé partout (authentification des messages Slurm) ------------------
if [ -f /tmp/munge.key ]; then
    install -o munge -g munge -m 0400 /tmp/munge.key /etc/munge/munge.key
    rm -f /tmp/munge.key
fi
svc munge

# --- 4. Système de fichiers partagé /shared (binaire CI, Spack, sorties des jobs) --------
# /home n'est pas partagé : gcloud y crée les comptes SSH avec des UID différents par VM.
mkdir -p "$SHARED"
if [ "$ROLE" = controller ]; then
    install -d -o ci -g ci -m 0755 "$SHARED/ci"
    [ -f "$SHARED/ci/.bashrc" ] || { cp -r --update=none /etc/skel/. "$SHARED/ci/"; chown -R ci:ci "$SHARED/ci"; }
    grep -q SPACK_ROOT "$SHARED/ci/.bashrc" || cat >> "$SHARED/ci/.bashrc" <<'EOF'
export SPACK_ROOT=$HOME/spack
[ -f "$SPACK_ROOT/share/spack/setup-env.sh" ] && . "$SPACK_ROOT/share/spack/setup-env.sh"
EOF
    NODE_IP=$(getent ahostsv4 "$NODE" | awk 'NR == 1 {print $1}')
    if [ -n "$NODE_IP" ]; then
        mkdir -p /etc/exports.d
        echo "$SHARED ${NODE_IP}(rw,sync,no_subtree_check)" > /etc/exports.d/mpiflow.exports
        exportfs -ra
        svc nfs-server
        say "NFS : $SHARED exporté vers $NODE ($NODE_IP)"
    else
        say "NFS : $NODE introuvable, export non configuré"
    fi
else
    grep -q " $SHARED nfs" /etc/fstab || echo "$CTL:$SHARED $SHARED nfs defaults,_netdev 0 0" >> /etc/fstab
    for _ in $(seq 12); do
        mountpoint -q "$SHARED" && break
        mount "$SHARED" 2>/dev/null || sleep 5
    done
    mountpoint -q "$SHARED" || { say "échec du montage NFS de $CTL:$SHARED"; exit 1; }
    say "NFS : $CTL:$SHARED monté sur $SHARED"
fi

# --- 5. slurm.conf, identique sur les deux nœuds ---------------------------------------
# matériel décrit par slurmd -C (les deux VM ont le même type), mémoire arrondie par défaut
HW=$(slurmd -C | head -1 | sed -E 's/^NodeName=[^ ]+ //; s/ UpTime=.*//')
MEM=$(sed -E 's/.*RealMemory=([0-9]+).*/\1/' <<< "$HW")
HW=$(sed -E "s/RealMemory=[0-9]+/RealMemory=$((MEM * 90 / 100))/" <<< "$HW")
install -d -o slurm -g slurm /var/spool/slurmctld /var/log/slurm
install -d /var/spool/slurmd
cat > /etc/slurm/slurm.conf <<EOF
# slurm.conf -- mini-cluster mpiflow : deux VM GCP (généré par cluster/node_setup.sh)
ClusterName=mpiflow
SlurmctldHost=${CTL}
SlurmUser=slurm
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldPidFile=/run/slurmctld/slurmctld.pid
SlurmdPidFile=/run/slurm/slurmd.pid
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
# suivi des processus sans cgroups : suffisant pour un mini-cluster de TP
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU
SlurmdParameters=config_overrides
MpiDefault=none
# un nœud qui revient (slurmd relancé) est remis en service automatiquement
ReturnToService=2
# nœud déclaré DOWN après 60 s sans réponse (300 s par défaut) : NODE_FAIL observable
SlurmdTimeout=60
# un job terminé reste visible par scontrol pendant 5 min
MinJobAge=300
# comptabilité (sacct) via slurmdbd + MariaDB sur le nœud de connexion
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=${CTL}
JobAcctGatherType=jobacct_gather/linux
JobCompType=jobcomp/none
NodeName=${CTL},${NODE} ${HW} State=UNKNOWN
PartitionName=debug Nodes=ALL Default=YES MaxTime=00:30:00 State=UP
EOF
chmod 644 /etc/slurm/slurm.conf

# --- 6. Contrôleur : comptabilité puis ordonnanceur --------------------------------------
if [ "$ROLE" = controller ]; then
    svc mariadb
    DBCONF=/etc/slurm/slurmdbd.conf
    PASS=$(sed -n 's/^StoragePass=//p' "$DBCONF" 2>/dev/null || true)
    PASS=${PASS:-$(head -c 18 /dev/urandom | base64 | tr -d '/+=')}
    mysql <<EOF
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '${PASS}';
ALTER USER 'slurm'@'localhost' IDENTIFIED BY '${PASS}';
GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
EOF
    cat > "$DBCONF" <<EOF
AuthType=auth/munge
DbdHost=localhost
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=${PASS}
StorageLoc=slurm_acct_db
EOF
    chown slurm:slurm "$DBCONF"
    chmod 600 "$DBCONF"
    svc slurmdbd
    for _ in $(seq 30); do sacctmgr -n list cluster >/dev/null 2>&1 && break; sleep 2; done
    sacctmgr -i add cluster mpiflow > /dev/null 2>&1 || true
    svc slurmctld

    # Spack dans /shared : même installation vue par les deux nœuds
    if [ ! -d "$SHARED/ci/spack" ]; then
        say "clonage de Spack v1.2.2"
        runuser -u ci -- git clone -q --depth=1 -b v1.2.2 https://github.com/spack/spack.git "$SHARED/ci/spack"
    fi
fi

svc slurmd
sleep 3
say "terminé : $(sinfo -h -o '%P %a %D %T' 2>/dev/null | tr '\n' ' ')"

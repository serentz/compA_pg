# Création des 2 VM sous Hyper-V

Le script `infra/hyperv/create_vms.ps1` crée le réseau et les 2 VM **et installe Ubuntu sans intervention** (autoinstall). Il est rejouable : `-Destroy` supprime tout, on relance, on obtient les mêmes VM.

| VM | Rôle | OS | IP | vCPU / RAM / disque |
|---|---|---|---|---|
| `pgbastion` | Script `compa_pg.sh`, Python, `psql`, Grafana | Ubuntu Server 24.04 LTS | 192.168.60.10 | 2 / 4 Go / 30 Go |
| `pgdb01` | PostgreSQL : base de résultats (5432) + clusters de test `pga` (5433) et `pgb` (5434) | Ubuntu Server 24.04 LTS | 192.168.60.11 | 2 / 4 Go / 40 Go |

Le PC hôte est la passerelle (192.168.60.1) : NAT vers Internet, VM joignables depuis le PC. Pas de DHCP : les IP fixes sont écrites dans la configuration d'installation.

Réseau (`comparg-net`, 192.168.60.0/24), noms de VM et dossier (`I:\POC\HyperV_pg`) sont distincts du POC `comparaison_ase` (192.168.50.0/24, `bastion`, `pg01`...) : les deux environnements peuvent tourner en même temps.

## 1. Prérequis

- Windows 10/11 Pro, Enterprise ou Éducation avec Hyper-V : `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All` (PowerShell administrateur), puis redémarrage.
- 8 Go de RAM libres pour les 2 VM et environ 70 Go de disque.
- L'ISO **Ubuntu Server** (`ubuntu-24.04.5-live-server-amd64.iso`, releases.ubuntu.com/24.04/). Pas l'ISO « desktop ».
- Un utilisateur et un mot de passe à choisir, identiques sur les 2 VM (`admin01` par défaut). Le mot de passe est demandé par le script, jamais écrit dans git.

## 2. Lancer

PowerShell **en administrateur**, depuis le dossier du dépôt :

```
Set-ExecutionPolicy -Scope Process Bypass
.\infra\hyperv\create_vms.ps1 -UbuntuIso "K:\ShareLinux\Image ISO\ubuntu-24.04.5-live-server-amd64.iso"
```

`-UbuntuIso` attend le chemin complet du fichier `.iso`, pas celui du dossier.

Le script :
1. crée le commutateur interne `comparg-net` et le NAT 192.168.60.0/24 ;
2. crée les 2 VM (génération 2, Secure Boot réglé pour Linux, démarrage disque puis DVD) ;
3. prépare pour chacune un petit disque de configuration (volume `CIDATA`) : IP fixe, nom, utilisateur, SSH, disque entier, `/etc/hosts`, clavier français ;
4. démarre les VM, ouvre leurs consoles et attend (10 à 20 minutes) ;
5. quand les VM se sont éteintes seules, retire l'ISO et les disques de configuration (ils contiennent le mot de passe), redémarre les VM et attend SSH ;
6. affiche pour chaque VM la commande `ssh` à utiliser.

Pendant l'installation, si la console demande `Continue with autoinstall?`, taper `yes` puis Entrée.

Options utiles : `-AdminUser`, `-SshPublicKeyFile` (par défaut `~\.ssh\id_ed25519.pub` ou `id_rsa.pub` s'ils existent, la clé est installée sur les 2 VM), `-Keyboard` (défaut `fr`), `-VmRoot`, `-Subnet`, `-SwitchName`, `-NoConsole`.

## 3. Recommencer de zéro

```
.\infra\hyperv\create_vms.ps1 -Destroy
```

Après confirmation (`OUI`), supprime les 2 VM et leurs disques. Le réseau est conservé. `-Only pgdb01` limite l'opération à une VM. Relancer ensuite la commande de la section 2.

## 4. En cas de problème

| Symptôme | Piste |
|---|---|
| `Il faut le chemin complet d'un fichier .iso` | Donner le fichier, pas le dossier |
| `VM deja presentes` | `-Destroy` puis relancer |
| Console noire au démarrage | Secure Boot : vérifier `Get-VMFirmware -VMName pgdb01` (modèle *MicrosoftUEFICertificateAuthority*) |
| L'installateur pose des questions (langue, réseau…) | La configuration n'a pas été lue : vérifier que la VM a 2 disques (`Get-VMHardDiskDrive -VMName pgdb01`) |
| Le script s'arrête sur le délai | Regarder les consoles, relancer avec `-Destroy` puis sans |
| `SSH ne repond pas` en fin de script | Console de la VM : `ip a` doit montrer l'IP du tableau, `systemctl status ssh` |

Après connexion : `ping 8.8.8.8` et `ping ubuntu.com` doivent répondre depuis chaque VM.

## 5. Point de contrôle

Quand les 2 VM répondent en SSH :

```
Stop-VM -Name pgdb01,pgbastion
Checkpoint-VM -Name pgdb01,pgbastion -SnapshotName os-pret
Start-VM -Name pgdb01,pgbastion
```

## 6. Suite : PostgreSQL sur `pgdb01`

> **Chemin court** : les archives du dossier `Deploy/` font les étapes 6 et 7 (PostgreSQL, base de résultats, clusters de test, comparateur, Grafana) : voir [deploiement_archives.md](deploiement_archives.md). Les étapes à la main ci-dessous restent valables.

`ssh admin01@192.168.60.11`, puis :

```
sudo apt update && sudo apt -y upgrade
sudo apt install -y postgresql
sudo -u postgres psql -c "CREATE ROLE compa_app LOGIN CREATEROLE"
sudo -u postgres psql -c "\password compa_app"
sudo -u postgres createdb -O compa_app compa
sudo sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
echo "host compa all 192.168.60.0/24 scram-sha-256" | sudo tee -a /etc/postgresql/16/main/pg_hba.conf
sudo systemctl restart postgresql
```

Charger le schéma de résultats (depuis le PC, copier le fichier, puis sur `pgdb01`) :

```
scp I:\POC\compa_pg\sql\postgres\create_schema.sql admin01@192.168.60.11:~/
```
```
psql -h 127.0.0.1 -U compa_app -d compa -f ~/create_schema.sql
psql -h 127.0.0.1 -U compa_app -d compa -c "\dt compa_pg.*"      # 17 tables
psql -h 127.0.0.1 -U compa_app -d compa -c "ALTER ROLE grafana_ro LOGIN"
psql -h 127.0.0.1 -U compa_app -d compa     # puis : \password grafana_ro
```

Clusters de test 5433 et 5434 avec leurs bases `poc_pg` (copier le dépôt sur `pgdb01`, par exemple `git clone`, ou `scp -r`) :

```
sudo bash infra/pg_clusters.sh
```

## 7. Suite : `pgbastion`

`ssh admin01@192.168.60.10`, puis :

```
sudo apt update && sudo apt install -y postgresql-client python3 git
git clone https://github.com/serentz/compa_pg
```

Déclarer les clusters comparés dans `compa_pg.config_compa_pg` (README, « Mise en place »), puis lancer `bash/compa_pg.sh` (README, « Lancer une comparaison »). Grafana : `grafana/README.md`.

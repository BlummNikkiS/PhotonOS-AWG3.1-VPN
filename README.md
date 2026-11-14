# PhotonOS-AWG3.1-VPN
Этот автоматический установщик позволяет развернуть роутер на основе photon os с помощью docker контейнеров.

Требуется преднастроить photon os для начала работы, информация в самом низу.

1. Создать папку командой:
mkdir -p /opt/split-gw/

2. С помощью программы "mobaxterm" положить в эту папку /opt/split-gw/ конфиг "awg.conf", который предварительно скачан с собственного awg сервера.

3. Положить этот скрипт "setup.sh" в папку /opt/split-gw/

4. Запустить скрипт командой "bash /opt/split-gw/setup.sh".

5. На машинах, которым требуется VPN, требуется прописать в качестве шлюза эту машину-роутер, а в качестве dns лучше указать 1.1.1.1.

Скрипт проверен только на Photon OS 5.0 GA с Docker 23.x и конфигом AmneziaWG на IPv4.

Дополнительно, если требуется помощь с настройкой photon os, например для Hyper-V:
1. Скачать тут: https://github.com/vmware/photon/wiki/Downloading-Photon-OS, выбираем "Minimal ISO x86_64", и создаём VM.
2. Для установки выдели 1гб ram.
3. После установки photon os minimal дистрибутива на hyper-v, для быстрого старта стоит выполнить ряд команд:
   1) Отредактируй "vi /etc/ssh/sshd_config" и установи "PermitRootLogin yes"
   2) "tdnf makecache"
   3) "systemctl enable docker && systemctl start docker"
   4) "tdnf install htop -y"
   5) "tdnf install -y hyper-v"
   6) "systemctl enable --now hv_kvp_daemon.service hv_vss_daemon.service hv_fcopy_daemon.service"
   7) "systemctl status hv_kvp_daemon hv_vss_daemon hv_fcopy_daemon"
   8) "reboot"

#linux #photonos #docker #hyperv #vpn #router #amnezia #singbox

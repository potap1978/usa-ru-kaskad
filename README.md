# USA-RU-KASKAD — AmneziaWG Client Universal Installer

Универсальный скрипт для автоматической установки и настройки **AmneziaWG клиента** на чистые серверы Debian/Ubuntu. Запускается одной командой без параметров, всё остальное — автоматически.

Второй скрипт (`amneziawg-server-install.sh`) ставит **AmneziaWG сервер** поверх — внешние клиенты подключаются и выходят в интернет через VPN-туннель.

---

## 🚀 Что делает `usa-ru-kaskad.sh`

| Этап | Действие |
|------|----------|
| **1. Зависимости** | `linux-headers`, `build-essential`, `dkms`, `git`, `curl`, `pkg-config`, `libmnl-dev`, `libsystemd-dev` |
| **2. Kernel Module** | Клонирует и собирает **последний master** `amneziawg-linux-kernel-module` → `make install` → `modprobe amneziawg` |
| **3. Tools** | Клонирует и собирает **последний master** `amneziawg-tools` → `make install PREFIX=/usr` (`awg`, `awg-quick`) |
| **4. Wrapper** | `/usr/local/bin/awg-quick-wrapper` — автоматически добавляет `Table = off` в любой конфиг перед запуском |
| **5. Systemd** | `awg-quick@.service` + `amneziawg-client-routing@.service` (клиент) + `amneziawg-routing@.service` (сервер), всё в автозагрузке |
| **6. Routing клиента** | IPv4 policy routing (fwmark 51821, table 51821) + SSH защита + bypass эндпоинта + отключение IPv6 на туннеле |
| **7. Routing сервера** | fwmark 51820, MASQUERADE подсети сервера через VPN-туннель, правило возврата трафика домой |
| **8. Управление** | `Start-VPN` / `Stop-VPN` (оба интерфейса) в `/usr/local/bin/` и копии в `/root/` |
| **9. Конфиг** | Пустой шаблон `/etc/amnezia/amneziawg/amneziawg.conf` — заполнить вручную |

---

## ✨ Ключевые фишки

- ✅ **Всегда актуальные версии** — модуль и tools собираются из **последнего master** GitHub
- ✅ **SSH не отваливается** — `prio 10 from <SERVER_IP> table main` (IP определяется через физический интерфейс, не через туннель) + маркировка SSH-трафика
- ✅ **Handshake не зацикливается** — `prio 900 to <ENDPOINT> table main`, эндпоинт всегда идёт напрямую, fwmark на интерфейсах корректные
- ✅ **Весь трафик через VPN** — policy routing с `Table = off`, без маршрутов внутрь туннеля
- ✅ **IPv6 отключён** — на туннельных интерфейсах
- ✅ **Любой конфиг работает** — wrapper добавляет `Table = off`, routing читает endpoint динамически из `awg show`
- ✅ **Домашние клиенты через VPN** — трафик подсети сервера MASQUERADE-ится в туннель
- ✅ **Простая смена конфига** — `Stop-VPN` → правишь конфиг → `Start-VPN`
- ✅ **Переживает ребут** — все сервисы в автозагрузке

---

## 📦 Установка (порядок важен)

```bash
# 1. Клиент (на чистом сервере, Debian/Ubuntu, root)
chmod +x usa-ru-kaskad.sh
sudo ./usa-ru-kaskad.sh
# Скрипт всё ставит сам, в конце пишет что делать дальше

# 2. Заполнить конфиг клиента
nano /etc/amnezia/amneziawg/amneziawg.conf
# Вписать: PrivateKey, Address, DNS, PublicKey пира, Endpoint

# 3. Запустить
~/Start-VPN

# 4. Проверить
curl -4 ifconfig.me   # должен показать IP VPN-провайдера
ping -c 3 8.8.8.8

# 5. Сервер для внешних клиентов (опционально, после клиента)
chmod +x amneziawg-server-install.sh
sudo ./amneziawg-server-install.sh
# Скрипт сам пропустит установку модуля/tools если они уже стоят,
# спросит параметры сервера и сгенерирует клиентские конфиги
```

---

## 🎮 Использование

```bash
~/Stop-VPN    # остановить клиент + сервер
~/Start-VPN   # запустить клиент + сервер (если конфиги заполнены)

# Смена конфига клиента:
~/Stop-VPN
nano /etc/amnezia/amneziawg/amneziawg.conf
~/Start-VPN

# Статус:
ip link show amneziawg; ip link show awg0
awg show amneziawg; awg show awg0
ip rule show
curl -4 ifconfig.me
```

---

## 🔧 Что создаётся на сервере

```
/usr/local/bin/
├── awg, awg-quick           # собраны из исходников
├── awg-quick-wrapper        # авто Table=off
├── amneziawg-client-routing # routing клиента (fwmark 51821)
├── amneziawg-client-teardown
├── amneziawg-setup-routing  # routing сервера (fwmark 51820)
├── amneziawg-teardown-routing
├── Start-VPN, Stop-VPN      # оба интерфейса

/root/
├── usa-ru-kaskad.sh
├── amneziawg-server-install.sh
├── Start-VPN, Stop-VPN      # копии
└── README.md

/etc/systemd/system/
├── awg-quick@.service
├── amneziawg-client-routing@.service
└── amneziawg-routing@.service

/etc/amnezia/amneziawg/
├── amneziawg.conf           # клиент (заполняется вручную)
├── awg0.conf                # сервер (генерирует server-installer)
└── params                   # параметры сервера
```

---

## 🛡 Безопасность

- Конфиги доступны только root (`chmod 600`)
- Всё собирается из официальных репозиториев AmneziaVPN, никаких сторонних бинарников
- SSH-трафик изолирован от туннеля через policy routing + fwmark

---

## 📋 Требования

- **OS**: Debian 11+/12, Ubuntu 20.04/22.04/24.04
- **Arch**: x86_64 (amd64)
- **Права**: root
- **Интернет**: для клонирования репозиториев и установки зависимостей

---

## 🤝 Репозитории

- [amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [amnezia-vpn/amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)

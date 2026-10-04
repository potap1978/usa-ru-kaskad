# AmneziaWG Client Universal Installer

Универсальный скрипт для автоматической установки и настройки **AmneziaWG клиента** на чистые серверы Debian/Ubuntu.

---

## 🚀 Что делает скрипт

За один запуск полностью настраивает рабочий AmneziaWG VPN клиент с сохранением SSH-доступа:

| Этап | Действие |
|------|----------|
| **1. Зависимости** | Устанавливает `linux-headers`, `build-essential`, `dkms`, `git`, `curl`, `pkg-config`, `libmnl-dev`, `libsystemd-dev` |
| **2. Kernel Module** | Клонирует и собирает **последний master** `amneziawg-linux-kernel-module` → `make install` → `modprobe amneziawg` |
| **3. Tools** | Клонирует и собирает **последний master** `amneziawg-tools` → `make install PREFIX=/usr` (awg, awg-quick) |
| **4. Wrapper** | Создаёт `/usr/local/bin/awg-quick-wrapper` — автоматически добавляет `Table = off` в любой конфиг перед запуском |
| **5. Systemd** | Два сервиса: `awg-quick@.service` (через wrapper) + `amneziawg-routing@.service` (routing + SSH защита) |
| **6. Routing** | IPv4 policy routing (fwmark 51820, table 51820) + SSH защита (prio 10 rule) + отключение IPv6 |
| **7. Управление** | Скрипты `Start-VPN` / `Stop-VPN` в `/usr/local/bin/` и копии в `/root/` |
| **8. Конфиг** | Генерирует `/etc/amnezia/amneziawg/amneziawg.conf` из переданных параметров |

---

## ✨ Ключевые фишки

- ✅ **Всегда актуальные версии** — kernel module и tools собираются из **последнего master** GitHub (никаких зашитых версий)
- ✅ **SSH не отваливается** — правило `prio 10 from <SERVER_IP> table main` + marking SSH трафика fwmark'ом
- ✅ **Весь трафик через VPN** — policy routing (fwmark 51820, table 51820) с `Table = off`
- ✅ **IPv6 отключён** — на интерфейсе и глобально
- ✅ **Любой конфиг работает** — wrapper сам добавляет `Table = off`, routing подхватывает endpoint из `awg show`
- ✅ **Простая смена конфига** — `Stop-VPN` → правь конфиг → `Start-VPN`

---

## 📦 Установка

```bash
# На новом сервере (Debian/Ubuntu)
git clone https://github.com/<your-repo>/amneziawg-installer.git
cd amneziawg-installer
chmod +x install-amneziawg.sh

# Интерактивно (спросит ключи)
sudo ./install-amneziawg.sh

# Или автоматически с параметрами
sudo ./install-amneziawg.sh \
  --private-key="YOUR_PRIVATE_KEY" \
  --public-key="PEER_PUBLIC_KEY" \
  --endpoint="95.173.217.71:51820" \
  --address="10.2.0.2/32" \
  --dns="10.2.0.1, 8.8.8.8" \
  --auto-start
```

### Параметры

| Флаг | Описание | Обязательный |
|------|----------|--------------|
| `--private-key` | PrivateKey клиента | Да |
| `--public-key` | PublicKey пира (сервера) | Да |
| `--endpoint` | IP:PORT сервера AmneziaWG | Да |
| `--address` | Адрес клиента в VPN (default: `10.2.0.2/32`) | Нет |
| `--dns` | DNS серверы (default: `10.2.0.1, 8.8.8.8`) | Нет |
| `--auto-start` | Автоматически запустить VPN после установки | Нет |

---

## 🎮 Использование после установки

```bash
# Остановить VPN
~/Stop-VPN

# Изменить конфиг
nano /etc/amnezia/amneziawg/amneziawg.conf

# Запустить VPN
~/Start-VPN

# Проверить статус
ip link show amneziawg
awg show
curl ifconfig.me
```

---

## 🔧 Что создаётся на сервере

```
/usr/local/bin/
├── awg                      # amneziawg binary
├── awg-quick                # amneziawg-quick binary
├── awg-quick-wrapper        # wrapper (авто Table=off)
├── amneziawg-setup-routing  # настройка routing + SSH защита
├── amneziawg-teardown-routing
├── Start-VPN
└── Stop-VPN

/root/
├── Start-VPN  (копия)
└── Stop-VPN   (копия)

/etc/systemd/system/
├── awg-quick@.service
└── amneziawg-routing@.service

/etc/amnezia/amneziawg/
└── amneziawg.conf           # ваш конфиг (правится вручную)
```

---

## 🛡 Безопасность

- Конфиг доступен только root (`chmod 600`)
- Kernel module и tools собираются из официальных репозиториев AmneziaVPN
- SSH-трафик изолирован от VPN-туннеля через policy routing
- Никаких сторонних бинарников — только исходный код с официальных репозиториев AmneziaVPN

---

## 📋 Требования

- **OS**: Debian 11+/12, Ubuntu 20.04/22.04/24.04
- **Arch**: x86_64 (amd64)
- **Права**: root
- **Интернет**: для клонирования репозиториев и скачивания зависимостей

---

## 🤝 Автор

Скрипт создан для быстрого развёртывания AmneziaWG клиентов на чистых серверах.  
Использует официальные репозитории:
- [amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
- [amnezia-vpn/amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)
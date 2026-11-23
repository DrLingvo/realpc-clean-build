# Контракт host-tools, версия 1

Общий документ двух репозиториев:
[realpc-clean-build](https://github.com/DrLingvo/realpc-clean-build) и
[pve-intel-gpu](https://github.com/DrLingvo/pve-intel-gpu).
Копии в обоих репозиториях должны совпадать.

## Зачем

Оба инструмента настраивают один и тот же хост Proxmox и одни и те же ВМ. realpc даёт
ВМ маскировку (QEMU/OVMF, ACPI, SMBIOS, `kvm.ko`), pve-intel-gpu — изображение через
iGPU (полный проброс с ROM или vGPU по SR-IOV). Смысл в совместной работе: ВМ с
профилем realpc и проброшенной iGPU. Без договорённостей каждый перетирает чужие
настройки, например `configvm` стирает IGD-аргументы, а откат realpc удаляет `hostpci`.

Любое изменение, которое затрагивает пункты ниже, делается сразу в обоих репозиториях,
с повышением `CONTRACT_VERSION` в обоих.

## 1. Блокировка

Все изменяющие режимы берут `flock` на `/run/lock/pve-host-tools.lock` (ожидание 60 с).
Режимы только для чтения (`check`, `status`) блокировку не берут.

## 2. Кто чем владеет в конфиге ВМ

| Ключ | Владелец | Правило |
| --- | --- | --- |
| `args` (основная часть) | realpc | `configvm` пересобирает строку и дописывает фрагменты из `args.d` |
| `args`: `-set device.hostpciN.{addr,bus,x-igd-*}` | pve-intel-gpu | только для своего индекса N |
| `machine`, `bios`, `localtime`, `tablet` | realpc | pve-intel-gpu их не меняет |
| `vga` | realpc; pve-intel-gpu, если проброшена `00:02.0` | при `hostpciN: …00:02.0` realpc `vga` не трогает |
| `hostpciN` с `00:02.x` и `00:1f.3` | pve-intel-gpu | realpc их не трогает |

Пишется только основная секция конфига (до первой строки `[…]`). Секции снапшотов не
трогаются.

## 3. Фрагменты `args`

`/etc/pve-host-tools/args.d/<vmid>/NN-<tool>.args`: одна строка аргументов QEMU.

- Владелец пишет и удаляет только свой файл; pve-intel-gpu использует
  `50-pve-intel-gpu.args`.
- Тот, кто пересобирает строку `args` (realpc `configvm`), дописывает в конец все
  фрагменты в порядке имён файлов.
- Тот, кто дописывает свой фрагмент сам (pve-intel-gpu), сначала убирает свои старые
  токены, поэтому повторный запуск не дублирует их.

## 4. Откат

- Конфиг ВМ целиком восстанавливается, только если он не менялся после собственной
  записи (сверка sha256). Иначе возвращаются только свои ключи из таблицы выше, а
  фрагменты `args.d` сохраняются.
- Порядок полного отката обратный установке: сначала pve-intel-gpu
  (`--mode revert --vmid N`, затем `--mode revert`), потом `realpc-setup.sh --mode rollback`.

## 5. Хост

| Что | Владелец |
| --- | --- |
| `pve-qemu-kvm`, `pve-edk2-firmware*`, их APT hold, `kvm*.ko` | realpc |
| `/etc/modprobe.d/pve-intel-gpu.conf`, `/etc/modules-load.d/pve-intel-gpu.conf`, `pve-intel-gpu-vfs.service` | pve-intel-gpu |
| Параметры ядра `intel_iommu`, `iommu`, `i915.*`, `module_blacklist=xe` | pve-intel-gpu (удаляет только добавленные им) |
| ROM в `/usr/share/kvm`, установленные pve-intel-gpu | pve-intel-gpu (удаляет, только если sha256 совпадает) |

Никто не делает `apt upgrade`. Пакеты ставятся только с `--no-upgrade`; если симуляция
`apt-get -s` затрагивает пакеты в hold, установка отменяется.

## 6. Состояние

Каждый инструмент ведёт свой файл `KEY=VALUE` и записывает в него `CONTRACT_VERSION`.
Чужое состояние можно только читать.

| Инструмент | Файл | Что читает сосед |
| --- | --- | --- |
| realpc | `/root/realpc/.realpc-state` | `INSTALL_MODE`, `RELEASE_TAG`, `KERNEL_RELEASE`, `CONTRACT_VERSION` |
| pve-intel-gpu | `/var/lib/pve-intel-gpu/state` | `HOST_MODE`, `CONTRACT_VERSION` |

`pve-intel-gpu.sh --mode check` предупреждает, если версии контракта расходятся или
realpc его ещё не поддерживает.

## 7. Порядок работы

1. `realpc-setup.sh --mode strong` (или `normal`), затем `--mode configvm --vmid N`.
2. `pve-intel-gpu.sh --mode passthrough --vmid N` (или `--mode vgpu --vmid N`).
3. Повторный `configvm` после смены профиля — фрагменты и `vga` сохраняются; со
   старым realpc без контракта нужен `pve-intel-gpu.sh --mode reapply --vmid N`.
4. Новое ядро: `realpc-setup.sh --mode update` (пересборка `kvm.ko`), проверить
   `dkms status` для i915-sriov, затем `pve-intel-gpu.sh --mode check`.

## 8. Тесты

Каждый репозиторий проверяет свою сторону контракта:

- realpc: `tests/test_setup.sh`, блок «host-tools contract» — фрагменты, `vga` при
  iGPU, снапшоты, откат по ключам, блокировка;
- pve-intel-gpu: `tests/run.sh` — сохранение чужих `args`, `reapply` после `configvm`,
  фрагмент `args.d`, отчёт о версии контракта, блокировка.

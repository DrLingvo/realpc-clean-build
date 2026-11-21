# pve-emu-realpc: чистая сборка из исходников

Пересборка пакетов проекта [AICodo/pve-emu-realpc](https://github.com/AICodo/pve-emu-realpc)
без единого бинарника от автора. Цель — PVE 9 (pve-qemu 11.1.3-4, pve-edk2-firmware 4.2026.08-1).

## Что входит и что нет

Воспроизводится **открытая часть** проекта — то, для чего автор публикует исходники
(sed-патчи, `smbios.c`, `qemu-autoGenPatch.patch`, патчи из
[`qemu-emu-realpc`](https://github.com/AICodo/qemu-emu-realpc), edk2- и seabios-патчи,
`.aml`). Всё это собирается здесь из официальных исходников Proxmox.

**Не воспроизводится как копия** закрытая часть «Strong», у которой автор исходников не даёт:

- `kvm.ko` (подменённый модуль ядра: прячет гипервызовы и т. п.) — **пока не реализовано**;
  планируется как открытый патч к ядру Proxmox, а не копия бинарника автора;
- Strong-сборка QEMU с пробросом датчиков CPU — заменяется **открытой реализацией**
  (`qemu/host-sensors.patch`, `HOST_SENSORS=1`), это замена, а не копия;
- скрипты `1plus/2plus/3StrongStart/3StrongEnd.sh` — исходники нигде не опубликованы.

Пока собирается только x86-64 под PVE 9. Сборок под старые PVE (7.x/8.x) и проверенной
ARM64-сборки здесь нет.

## Откуда что берётся

| Компонент | Источник | Как проверяется |
|---|---|---|
| QEMU | `git.proxmox.com/git/pve-qemu.git` @ `242e15da…` | хэш коммита сверяется в `build.sh`; подмодули и meson-subprojects закреплены хэшами внутри |
| OVMF | `git.proxmox.com/git/pve-edk2-firmware.git` @ `f37039e5…` | то же |
| Правки QEMU | `qemu/anti-detection.sh`, `qemu/smbios.patch` | текст; каждая замена обязана сработать, иначе сборка падает |
| Датчики CPU (опц.) | `qemu/host-sensors.patch` (`HOST_SENSORS=1`) | открытая замена Strong-функции; через MSR-filter отдаёт гостю термо-, perf- и RAPL-MSR хоста (Intel) |
| Правки OVMF | `edk2/anti-detection.sh` | то же |
| SeaBIOS | подмодуль QEMU (`roms/seabios`) + `seabios/seabios.patch` | собирается из исходников вместо готовых `bios*.bin` |
| ACPI (`ssdt*.aml`, `hpet.aml`) | `acpi/*.dsl` (декомпилированы из файлов автора) | компилируются `iasl`; результат **побайтно совпадает** с файлами автора (`SHA256SUMS.author`) |
| Логотип OVMF | генерируется (`tools/make-logo.py`) или ваш файл | чужие картинки не используются (парсер BMP в прошивке — поверхность атаки, см. LogoFAIL) |

Сборочный контейнер автора (`ghcr.io/aicodo/pve9docker`), его `.deb`, `bios*.bin`, `.aml`,
`Logo.bmp`, `bootsplash.jpg` и утилиты из `tools/` не используются.

## Открытая замена `kvm.ko` (Strong, Intel) — `kernel/`

Закрытый Strong-модуль ядра прячет гипервызовы KVM. Его исходников нет, поэтому поведение
реализовано заново своим кодом в исходниках ядра:

- `kernel/kvm-antidetect.py` — инъектор: `kvm_emulate_hypercall` и `emulator_fix_hypercall`
  начинают выдавать `#UD` (VMCALL/VMMCALL выглядят как на «голом» железе). Пути Xen и Hyper-V
  не трогаются. Мутные правки singlestep/AMD из бинарника **не** воспроизводятся намеренно.
- `kernel/build-kvm.sh` — собирает `kvm.ko` **на самом хосте** против его исходников и
  конфига, чтобы ABI (vermagic, CRC символов) точно совпал с запущенным ядром. Бинарник
  из CI сюда не кладётся сознательно: модуль обязан совпасть с конкретным ядром.
- `kernel/install-kvm.sh` — ставит с резервной копией и проверкой vermagic; `--revert` откат.

**Экспериментально и на весь хост.** Модуль `kvm.ko` общий: с ним все гости на хосте теряют
родные paravirt-гипервызовы KVM. Держите резервную копию и умейте загрузиться в прежнее ядро.
CI это не загружает и не тестирует — только проверяет, что инъектор даёт собираемый C.

## Установка и релизы

Готовые пакеты собираются в CI (workflow **build**) и публикуются в Releases (workflow
**release**, по тегу `v*`). На хосте PVE 9:

- `deploy/realpc-setup.sh` — скрипт «всё в одном» (режимы `check|normal|strong|configvm|rollback`):
  сам качает релиз нашего репозитория (или берёт файлы из `--dir`), ставит пакеты, в `strong`
  собирает и ставит наш `kvm.ko` на хосте, в `configvm` вписывает `args` с `host-sensors=on`,
  ведёт журнал и умеет откат. Пример: `./realpc-setup.sh --mode normal --yes`.
- `deploy/install-userspace.sh <каталог>` — простой вариант: ставит `.deb` (QEMU с доступным
  `host-sensors`, OVMF), кладёт `.aml`, делает `apt-mark hold`. Откат: `--revert`.
- `deploy/vm.example.conf` — пример конфига ВМ (по образцу авторского), с `host-sensors=on`.
- датчики CPU в госте: `host-sensors=on` в `-cpu` (Intel), нужен модуль ядра `msr` на хосте.

## Генератор профилей железа

Чтобы ВМ не делили один отпечаток (у всех одна плата/память/серийники), есть
`tools/gen-profile.py` — он выдаёт **согласованный** случайный профиль: сокет, тип/скорость/
форм-фактор/напряжение/парт/вендор памяти, CPU, плата, вендор BIOS, серийники и OUI MAC — всё
соответствует одной реальной платформе (без «DDR3 на LGA1700»). Два выхода: `profile.args`
(строка `args:`, работает с любой сборкой) и `profile.env` (правки `config.env`, нужны лишь
если тип/форм-фактор памяти профиля отличается от вашей сборки — тогда пересборка).

```
python3 tools/gen-profile.py --list                 # платформы
python3 tools/gen-profile.py --platform amd_desktop_am5 --kind gaming --out myprofile
python3 tools/gen-profile.py --platform intel_desktop_lga1700 --tsc-pin 1 --out myprofile
```
В `-cpu` профиль по умолчанию добавляет `pmu=on` (архитектурный PMU, иначе — признак ВМ;
`--pmu 0` выключает) и `host-sensors=on` для Intel. `--tsc-pin 1` дополнительно пинит
`tsc-frequency` под базовую частоту заявленной модели CPU — по умолчанию выключено,
т.к. требует аппаратного TSC-scaling на хосте и ломает миграцию (генератор печатает
предупреждение). Готовые эталоны — в `profiles/`.

## Детерминизм сборки

Бинарники **не** побайтово воспроизводимы: edk2 вставляет случайный stack-cookie при каждой
сборке, SeaBIOS — время сборки. Поэтому фиксируются и проверяются **входы**: апстрим-коммиты
закреплены в `config.env`, все патчи и скрипты — текстовые. `tools/source-hash.sh` печатает
единый `RECIPE-SHA256` рецепта (коммиты + патчи + скрипты): одинаковый хэш ⇒ одинаковые
исходники и правки, кто бы ни собирал. Контрольные суммы самих артефактов — в `SHA256SUMS`
релиза (совпадают у одинаковой сборочной среды, кроме отмеченных недетерминированных частей).

## Ограничения детекта по таймингам

Детект ВМ по таймингам — отдельный класс, который SMBIOS/ACPI-маскировка не закрывает.
Оценить, насколько ваша ВМ отличима, можно набором `tests/timing_tests/` (гостевые тесты
VM-exit/кэш/TSC/PMU/RAPL + аналайзер).

- **Латентность VM-exit — не скрывается на ванильном KVM.** `CPUID` и подобные инструкции
  всегда вызывают VM-exit; детектор, измеряющий их латентность (`rdtsc; cpuid; rdtsc`), увидит
  ВМ. Это known limitation, а не баг: обойти без аппаратных расширений нельзя.
- **Микроархитектурные side-channel'ы** (латентности кэшей/TLB, branch predictor) под EPT/NPT
  близки к железу, но тонкие детекты остаются возможны. Полная защита требует Intel TDX /
  AMD SEV-SNP либо тяжёлых патчей гипервизора с потерей производительности — здесь не делается.
- **PMU.** Архитектурный PMU (CPUID.0AH) в госте по умолчанию отсутствует — это признак ВМ.
  Закрывается флагом `-cpu ...,pmu=on` (генератор профилей добавляет его по умолчанию;
  `gen-profile.py --pmu 0` выключает). Включает KVM-vPMU, так что `pmu_check` проходит.
- **RAPL.** MSR энергопотребления (0x606/0x611/0x619/0x639/0x641) в госте по умолчанию
  отсутствуют. Два пути отдать их, **включать только один**:
  - *наш* `host-sensors` (`qemu/host-sensors.patch`, `HOST_SENSORS=1`) — отдаёт RAPL через
    KVM MSR-filter с реального CPU хоста (Intel), **сырые** попакетные счётчики. Удобно (одно
    свойство `-cpu`, заодно термо- и perf-MSR), максимум достоверности, но утекает суммарная
    энергия хоста в гостя. На многосокетном хосте — закрепить ВМ за одним сокетом.
  - *штатный upstream* `qemu-vmsr-helper` + `-accel kvm,rapl=on,rapl-helper-socket=…` — тот
    самый хелпер из обычного deb (ровно 4 RAPL-MSR). Энергия **виртуализируется** под каждую
    ВМ (изоляция), но при желании детектор может заметить, что цифры не совпадают с нагрузкой.
    RAPL-only: термо-/perf-MSR он не отдаёт — для них всё равно нужен `host-sensors`.
  Оба закрывают `rapl_check`. Выбор — достоверность (наш путь) против изоляции (upstream).
- **TSC.** Пин `tsc-frequency` в `-cpu` под заявленную модель CPU реализован в генераторе
  профилей (`gen-profile.py --tsc-pin 1`), **по умолчанию выключен**. Он делает
  измеряемую/сообщаемую частоту TSC согласованной с CPU, который мы выдаём в SMBIOS. Два
  условия: (1) хост должен поддерживать аппаратный TSC-scaling, иначе KVM начнёт
  перехватывать каждый RDTSC — медленно и *заметнее*, чем без пина; (2) live-migration между
  хостами с разным TSC **не поддерживается**. Поэтому опция и выключена по умолчанию.
- **VM-exit jitter (`VM_EXIT_JITTER`, экспериментально, выкл).** Опциональный хук в нашем
  `kvm.ko` (`kernel/kvm-cpuid-jitter.py`) добавляет случайную задержку в путь CPUID-exit.
  Честно: он поднимает **дисперсию** `rdtsc; cpuid; rdtsc` (может обмануть наивный детектор,
  ищущий низкую дисперсию), но **не снижает медиану** — детектор по медиане всё равно видит
  VM-exit, плюс добавляется латентность к каждому CPUID. Количественно компромисс считает
  `tests/timing_tests/jitter_report.py`. Даже собранный в модуль, хук инертен, пока не задан
  параметр `realpc_cpuid_jitter`.

`tests/timing_tests/reference/thresholds.json` перечисляет, что именно проверяется и с какими
порогами; `jitter_report.py` — что даёт и чего не даёт VM_EXIT_JITTER.

## Известные незакрытые места

- **Нет сборок** под старые PVE (7.x/8.x) и проверенной **ARM64**.
- **Подпись fw_cfg на порту** (`QEMU`) гость всё ещё читает; автор её не меняет, поэтому и
  здесь не меняется (смена сломала бы загрузку без согласованных правок OVMF/SeaBIOS).
- **`kvm.ko`** собирается только на хосте и не проходил загрузочного теста; он заменяет модуль
  ядра **для всего хоста** — все ВМ теряют родные paravirt-гипервызовы KVM.
- Профиль памяти/сокета в SMBIOS теперь настраиваемый (`config.env` + генератор профилей);
  осталось: опциональное скрытие subsystem vendor ID `0x1af4` у части устройств (в работе).

## Что изменено относительно скриптов автора

- **Порт на QEMU 11.1.** На 11.1.3 часть замен автора молча не срабатывала. Они перенесены
  на новое место в коде: модель CPU «QEMU Virtual CPU», версия SMBIOS type 1 (`pc-q35-11.1`),
  ревизия прошивки IDE/SCSI-дисков `2.5+`. Убраны замены для файлов, которых в QEMU 11 нет.
- **Убраны метки автора.** `aiiaicodo`, `666`, `114514` и прочие узнаваемые значения
  в серийниках, SMART и SMBIOS (по ним такую ВМ легко опознать) вынесены в `config.env`.
- **Версия SeaBIOS** больше не содержит `…-dirty-<дата>-<хост>-prebuilt.qemu.org`.
- **Производитель UEFI.** И Proxmox, и сборки автора сообщают «Proxmox distribution of EDK II».
  По умолчанию заменено (`OVMF_FW_VENDOR`). Если оставить пустым, будет как у автора.
- **SeaBIOS-патч автора** рассчитан на Q35 с изменёнными ID (0xdd66/0xdd88). В OVMF Strong
  такой поддержки нет, поэтому эти ID в патче возвращены к стандартным. Остальное сохранено.

## Что удалось восстановить из закрытой версии «Strong»

- **OVMF Strong** я разобрал помодульно и сравнил с обычной сборкой. Единственное
  функциональное отличие — таблица PCI ID видеодрайвера (`QemuVideoDxe`): stdvga `0x1234→0x6666`,
  virtio-vga `0x1af4→0x8085`, vmware-svga `0x15ad→0x8085`. Всё остальное — шум пересборки
  (stack-cookie, сдвиг адресов PEI-модулей). Воспроизводится опцией `STRONG_PCI_IDS=1`,
  которая меняет и QEMU (`qemu/strong-pci-ids.sh`), и OVMF.
- **QEMU Strong** (проброс температуры/частоты/напряжения/мощности CPU) — **ещё не разобран**:
  нужен файл `pve-qemu-kvm_*_Strong.deb`. Присланный `pve-qemu-kvm_11_1_3-3_amd64.deb` —
  обычная сборка. Я проверил её: новых исходников нет, `qemu-vmsr-helper` штатный (разрешены
  только 4 MSR RAPL), кода чтения датчиков нет. То есть обычная версия соответствует открытым
  скриптам.

## Сборка на хосте PVE (в одноразовом LXC)

1. Создайте контейнер Debian 13 (примерно 60 ГБ диска, 8 ГБ RAM, 4+ ядра; сборка идёт 1–3 часа):
   ```bash
   pveam update
   pveam available | grep debian-13          # возьмите точное имя шаблона
   pveam download local debian-13-standard_<версия>_amd64.tar.zst
   pct create 9100 local:vztmpl/debian-13-standard_<версия>_amd64.tar.zst \
     --hostname realpc-build --cores 4 --memory 8192 --swap 4096 \
     --rootfs local-lvm:60 --net0 name=eth0,bridge=vmbr0,ip=dhcp \
     --unprivileged 1 --features nesting=1
   pct start 9100
   ```
2. Подключите в контейнере репозиторий Proxmox. Ключ берётся с вашего же хоста, то есть
   ему вы уже доверяете:
   ```bash
   pct push 9100 /usr/share/keyrings/proxmox-archive-keyring.gpg /usr/share/keyrings/proxmox-archive-keyring.gpg
   pct exec 9100 -- bash -c 'cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
   Types: deb
   URIs: http://download.proxmox.com/debian/pve
   Suites: trixie
   Components: pve-no-subscription
   Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
   EOF'
   ```
3. Скопируйте набор, проверьте `config.env` и запустите:
   ```bash
   pct push 9100 realpc-clean-build.tar.gz /root/realpc-clean-build.tar.gz
   pct exec 9100 -- bash -c 'cd /root && tar xzf realpc-clean-build.tar.gz && cd realpc-clean-build && nano config.env && ./build.sh'
   ```
4. Заберите результат и удалите контейнер:
   ```bash
   pct pull 9100 /root/realpc-clean-build/out/<файл> /root/<файл>   # .deb и .aml из out/
   pct destroy 9100
   ```

## Установка

```bash
dpkg -i pve-qemu-kvm_11.1.3-4_amd64.deb pve-edk2-firmware-ovmf_4.2026.08-1_all.deb
apt-mark hold pve-qemu-kvm pve-edk2-firmware-ovmf   # иначе apt upgrade вернёт штатные
cp ssdt.aml ssdt-ec.aml hpet.aml /root/              # или ssdt-battery.aml вместо ssdt.aml
```
Откат: `apt-mark unhold pve-qemu-kvm pve-edk2-firmware-ovmf && apt reinstall pve-qemu-kvm pve-edk2-firmware-ovmf`.

Настройка ВМ — как в README автора: OVMF + q35, SATA-диск, e1000, `balloon: 0`, тот же `args:`
(`-acpitable file=/root/ssdt.aml …`, `-smbios type=0..17 …`, `-cpu host,hypervisor=off,…`).
При `STRONG_PCI_IDS=1` virtio-устройства и драйверы virtio-win работать не будут.

## Проверка результата

- `out/qemu-applied.diff`, `out/edk2-applied.diff`, `out/seabios-applied.diff` — полный список
  изменений в исходниках. Их стоит просмотреть: это всё, что отличает сборку от штатного Proxmox.
- `out/SHA256SUMS` — хэши результатов.
- Сборки воспроизводимы не побайтно: в edk2 при каждой сборке генерируется случайный
  stack-cookie, у SeaBIOS в бинарнике остаётся время сборки.

## Сборка в GitHub Actions

`.github/workflows/build.yml` собирает QEMU и OVMF+ACPI параллельно в чистом `debian:trixie`
(`ci/container-build.sh`), затем ставит пакеты в свежий контейнер и прогоняет проверки
(`ci/container-test.sh`, `tests/`): дамп fw_cfg/ACPI/SMBIOS через qtest, поиск известных
строк-утечек в бинарниках и в прошивке. Результаты — в Artifacts запуска.

Ключ репозитория Proxmox по умолчанию скачивается и его отпечаток печатается в логе. Чтобы не
доверять загрузке, положите в `ci/proxmox-archive-keyring.gpg` файл
`/usr/share/keyrings/proxmox-archive-keyring.gpg` со своего хоста PVE.

**Кэширование.** CI кэширует `ccache` (компиляция QEMU/edk2) и `.git`-объекты закреплённых
исходников (ключ — коммиты из `config.env`). Первый прогон наполняет кэш; повторные с теми же
исходниками и патчами собираются заметно быстрее (компиляция идёт из ccache, исходники не
перекачиваются). Для одного ref одновременно идёт только одна сборка (новый пуш отменяет
незавершённый старый). Правки доков/скриптов (`tools/`, `deploy/`, `kernel/`, `*.md`) сборку
не запускают.

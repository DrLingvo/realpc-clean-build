#!/usr/bin/env bash
###############################################################################
# realpc-setup.sh — установка нашей ОТКРЫТОЙ сборки на Proxmox VE 9
#   репозиторий: DrLingvo/realpc-clean-build  (пересборка pve-emu-realpc из исходников)
#
#   Режимы: check | normal | strong | configvm | rollback
#   - normal : качает релиз (QEMU с host-sensors + OVMF + .aml), ставит, held;
#   - strong : то же + собирает наш открытый kvm.ko НА ХОСТЕ и ставит его
#              (это замена закрытого модуля автора; метка проверяется modinfo realpc);
#   - configvm: раскладывает .aml и вписывает args (с host-sensors=on) в конфиг ВМ;
#   - rollback: откат пакетов/модуля/конфига по журналу состояния.
#
#   Файлы релиза скрипт качает сам (--download 1) ИЛИ берёт готовые из --dir (--download 0).
#   Настройка — в секции CONFIG ниже ИЛИ параметрами (параметр главнее). Справка: --help
#   Параметры: --mode M --release R --dir D --download 0|1 --log none|normal|debug
#              --logfile PATH --vmid N --cpu-model "..." --ksrc PATH --yes
###############################################################################

############################### CONFIG (правь тут) ############################
CFG_REPO="DrLingvo/realpc-clean-build"   # НАШ репозиторий релизов
CFG_MODE="check"                          # check|normal|strong|configvm|rollback
CFG_RELEASE="latest"                      # latest | тег релиза (напр. build-20261121-091114)
CFG_WORKDIR="/root/realpc"                # рабочая папка (качаем сюда / ставим отсюда)
CFG_DOWNLOAD=1                            # 1 — качать с GitHub; 0 — брать готовое из WORKDIR
CFG_LOG="none"                            # none|normal|debug — пишет в файл, на вывод не влияет
CFG_LOGFILE=""                            # пусто = <папка скрипта>/<имя скрипта>.log
CFG_VMID=""                               # для configvm: номер ВМ
CFG_YES=0                                 # 1 — не спрашивать подтверждений
CFG_KSRC=""                               # strong: путь к исходникам ядра (пусто = apt-get source)

# Все файлы берутся из одного релиза и обязательно проверяются по SHA256SUMS.
CFG_AML=(ssdt.aml ssdt-ec.aml hpet.aml)
CFG_KERNEL_ASSET="realpc-kernel-tools.tar.gz"

# Шаблон args. __AML__ -> путь к папке .aml, __CPUMODEL__ -> модель CPU.
# ВАЖНО: host-sensors=on включает проброс датчиков хоста (наша открытая реализация, Intel).
CFG_ARGS_TEMPLATE='-acpitable file=__AML__/ssdt.aml -acpitable file=__AML__/ssdt-ec.aml -acpitable file=__AML__/hpet.aml -cpu host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true,pmu=on,host-sensors=on -smbios type=0,vendor="American Megatrends International LLC.",version=H3.7G,date=02/21/2023,release=3.7 -smbios type=1,manufacturer="Maxsun",product="MS-Terminator B760M",version="VER:H3.7G" -smbios type=2,manufacturer="Maxsun",product="MS-Terminator B760M",version="VER:H3.7G" -smbios type=3,manufacturer="Default string",version="Default string" -smbios type=17,serial=66666666,asset=9876543210 -smbios type=4,manufacturer="Intel(R) Corporation",version="__CPUMODEL__" -smbios type=9 -smbios type=8'

# Рекомендуемое железо ВМ, которое выставит configvm (пусто — не трогать)
CFG_VM_SET="--machine q35 --bios ovmf --vga vmware --localtime 1 --tablet 1"
############################# /CONFIG #########################################

set -uo pipefail

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SELF_DIR="$(dirname "$SELF")"; SELF_NAME="$(basename "$SELF")"; SELF_NAME="${SELF_NAME%.*}"

REPO="$CFG_REPO"; MODE="$CFG_MODE"; RELEASE="$CFG_RELEASE"; WORKDIR="$CFG_WORKDIR"
DOWNLOAD="$CFG_DOWNLOAD"; LOG="$CFG_LOG"; LOGFILE="$CFG_LOGFILE"; VMID="$CFG_VMID"
YES="$CFG_YES"; CPU_MODEL=""; KSRC="$CFG_KSRC"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    --dir) WORKDIR="$2"; shift 2 ;;
    --download) DOWNLOAD="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --logfile) LOGFILE="$2"; shift 2 ;;
    --vmid) VMID="$2"; shift 2 ;;
    --cpu-model) CPU_MODEL="$2"; shift 2 ;;
    --ksrc) KSRC="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#\{1,\} \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

WORKDIR="$(readlink -m "$WORKDIR")"
[[ "$VMID" =~ ^[0-9]*$ ]] || { echo "--vmid должен быть числом" >&2; exit 2; }
[[ "$DOWNLOAD" == 0 || "$DOWNLOAD" == 1 ]] || { echo "--download: 0 или 1" >&2; exit 2; }
[[ -z "$LOGFILE" ]] && LOGFILE="$SELF_DIR/$SELF_NAME.log"
TRANSACTION=0
COMPLETED=0
TRANSACTION_PKGS=0
TRANSACTION_MODULE=0
TRANSACTION_VMID=""
RESOLVED_TAG=""

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_rst=$'\e[0m'
_logw(){ [[ "$LOG" == none ]] && return 0
  [[ "$1" == DEBUG && "$LOG" != debug ]] && return 0
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOGFILE" 2>/dev/null || true; }
ok(){   echo "${c_grn}[ok]${c_rst}   $*"; _logw INFO "$*"; }
info(){ echo "         $*";                _logw INFO "$*"; }
warn(){ echo "${c_yel}[!]${c_rst}    $*";  _logw WARN "$*"; }
err(){  echo "${c_red}[err]${c_rst}  $*" >&2; _logw ERROR "$*"; }
dbg(){  _logw DEBUG "$*"; }
die(){  err "$*"; exit 1; }
confirm(){ [[ "$YES" == 1 ]] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

if [[ "$LOG" != none ]]; then
  : >>"$LOGFILE" 2>/dev/null || { echo "Не могу писать в лог $LOGFILE"; LOG=none; }
  _logw INFO "=== старт: mode=$MODE release=$RELEASE dir=$WORKDIR download=$DOWNLOAD ==="
  echo "Лог: $LOG → $LOGFILE"
fi
[[ "$LOG" == debug ]] && { exec {XFD}>>"$LOGFILE"; export BASH_XTRACEFD=$XFD; set -x; }

need_root(){ [[ $EUID -eq 0 ]] || die "Запускай от root."; }
cpu_vendor(){ case "$(grep -m1 '^vendor_id' /proc/cpuinfo|awk '{print $3}')" in
  GenuineIntel) echo intel;; AuthenticAMD) echo amd;; *) echo unknown;; esac; }
cpu_model(){ grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//'; }
# наш модуль опознаётся меткой из kernel/kvm-antidetect.py (MODULE_INFO realpc)
mod_is_ours(){ modinfo kvm 2>/dev/null | grep -q '^realpc:'; }

STATE="$WORKDIR/.realpc-state"
st_set(){ mkdir -p "$WORKDIR" || die "не могу создать $WORKDIR"
          grep -v "^$1=" "$STATE" 2>/dev/null >"$STATE.tmp" || true
          echo "$1=$2" >>"$STATE.tmp" || die "не могу записать $STATE.tmp"
          mv "$STATE.tmp" "$STATE" || die "не могу обновить $STATE"; dbg "state $1=$2"; }
st_get(){ [[ -f "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | tail -1; }

restore_package(){
  local pkg=$1 version hold backup failed=0
  version="$(st_get "OLD_${pkg}_VERSION")"; hold="$(st_get "OLD_${pkg}_HOLD")"
  backup="$(st_get "OLD_${pkg}_DEB")"
  # Путь привязан к конкретной сохранённой версии; произвольный старый .deb не подходит.
  if [[ -n "$backup" && ! -f "$backup" ]]; then
    err "Сохранённый пакет отсутствует: $backup"; backup=""
  fi
  if [[ -n "$backup" ]]; then
    apt-get install -y --allow-downgrades "$backup" || failed=1
  elif [[ -n "$version" ]]; then
    apt-get install -y --allow-downgrades --reinstall "$pkg=$version" || failed=1
  else
    warn "Нет сохранённой версии $pkg — оставляю текущий пакет."; failed=1
  fi
  if [[ "$hold" == 1 ]]; then apt-mark hold "$pkg" >/dev/null || failed=1
  else apt-mark unhold "$pkg" >/dev/null 2>&1 || failed=1; fi
  return "$failed"
}

rollback(){
  local auto=${1:-0} failed=0
  warn "ОТКАТ изменений…"
  # Автооткат затрагивает только то, что текущая операция реально начала менять.
  # Состояние прошлой успешной установки остаётся доступным для ручного rollback.
  if [[ "$auto" != 1 || "$TRANSACTION_MODULE" == 1 ]]; then
    local mb mp; mb="$(st_get MODULE_BACKUP)"; mp="$(st_get MODULE_PATH)"
    if [[ -n "$mb" && -f "$mb" && -n "$mp" ]]; then
      local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}')"
      if [[ -z "$run" ]]; then
        rmmod kvm_intel 2>/dev/null||true; rmmod kvm_amd 2>/dev/null||true; rmmod kvm 2>/dev/null||true
        if cp -f "$mb" "$mp" && depmod "$(uname -r)" && modprobe "kvm_$(cpu_vendor)"; then
          ok "kvm.ko восстановлен из $mb"
        else err "Не удалось восстановить kvm.ko — восстанови $mb в $mp вручную."; failed=1; fi
      else err "ВМ запущены — модуль не восстановлен. Останови ВМ и повтори rollback."; failed=1; fi
    fi
  fi
  local restore_pkgs=0
  if [[ "$auto" == 1 ]]; then
    [[ "$TRANSACTION_PKGS" == 1 ]] && restore_pkgs=1
  elif [[ "$(st_get PKGS)" == "1" ]]; then
    restore_pkgs=1
  fi
  if [[ "$restore_pkgs" == 1 ]]; then
    if [[ "$auto" == 1 ]] || confirm "Восстановить исходные QEMU/OVMF из резервных пакетов?"; then
      restore_package pve-qemu-kvm || failed=1
      restore_package pve-edk2-firmware-ovmf || failed=1
      [[ "$failed" == 0 ]] && st_set PKGS 0
    fi
  fi
  local ids id cb cf
  if [[ "$auto" == 1 ]]; then ids="$TRANSACTION_VMID"; else ids="$(st_get CONF_VMS)"; fi
  for id in $ids; do
    cb="$(st_get "CONF_BAK_$id")"; cf="$(st_get "CONF_PATH_$id")"
    if [[ -n "$cb" && -f "$cb" && -n "$cf" ]]; then
      cp -f "$cb" "$cf" && ok "Конфиг ВМ $id восстановлен" || { err "Не удалось восстановить $cf"; failed=1; }
    fi
  done
  # Совместимость с состоянием старых версий установщика — только для явного ручного отката.
  if [[ "$auto" != 1 ]]; then
    cb="$(st_get CONF_BAK)"; cf="$(st_get CONF_PATH)"
    if [[ -n "$cb" && -f "$cb" && -n "$cf" ]]; then cp -f "$cb" "$cf" || failed=1; fi
  fi
  if [[ "$failed" == 0 ]]; then ok "Откат завершён успешно."; else err "Откат завершён С ОШИБКАМИ."; fi
  return "$failed"
}

transaction_begin(){
  TRANSACTION=1; COMPLETED=0; TRANSACTION_PKGS=0; TRANSACTION_MODULE=0; TRANSACTION_VMID=""
  trap on_exit EXIT
}
transaction_end(){ COMPLETED=1; TRANSACTION=0; trap - EXIT; }
on_exit(){
  local rc=$?; trap - EXIT
  if [[ "$TRANSACTION" == 1 && "$COMPLETED" == 0 ]]; then
    err "Операция не завершена (код $rc) — запускаю автоматический откат."
    rollback 1 || true
  fi
  exit "$rc"
}

# ── скачивание и обязательная проверка одного релиза ─────────────────────────
dl(){
  local tmp="$2.part"; rm -f "$tmp"; info "скачиваю $(basename "$2")"
  if curl -fSL --retry 3 -o "$tmp" "$1" || wget -O "$tmp" "$1"; then
    mv "$tmp" "$2"
  else rm -f "$tmp"; die "не скачал: $1"; fi
}
pick(){ echo "$1" | grep -E "$2" | head -1; }

verify_assets(){
  local dir=$1; shift
  python3 - "$dir" "$@" <<'PY'
import hashlib, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
required = sys.argv[2:]
manifest = {}
try:
    lines = (root / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
except OSError as exc:
    raise SystemExit(f"SHA256SUMS обязателен: {exc}")
for line in lines:
    match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
    if match:
        manifest[pathlib.PurePath(match[2]).name] = match[1].lower()
for name in required:
    expected = manifest.get(name)
    if not expected:
        raise SystemExit(f"SHA256SUMS не содержит обязательный файл: {name}")
    path = root / name
    try:
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc:
        raise SystemExit(str(exc))
    if actual != expected:
        raise SystemExit(f"SHA256 НЕ СОВПАЛ: {name}")
print(f"SHA-256 проверен для {len(required)} обязательных файлов")
PY
}

fetch_assets(){
  mkdir -p "$WORKDIR"
  command -v python3 >/dev/null || die "нужен python3"
  if [[ "$DOWNLOAD" == 1 ]]; then
    command -v curl >/dev/null || die "нужен curl для GitHub API"
    [[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || die "недопустимый тег релиза: $RELEASE"
    local api="https://api.github.com/repos/$REPO/releases/latest"
    [[ "$RELEASE" != latest ]] && api="https://api.github.com/repos/$REPO/releases/tags/$RELEASE"
    local json; json=$(mktemp)
    curl -fsSL --retry 3 -o "$json" "$api" || die "не получил метаданные релиза $RELEASE"
    RESOLVED_TAG=$(python3 - "$json" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
print(obj["tag_name"])
PY
)
    local urls; urls=$(python3 - "$json" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding="utf-8"))
for asset in obj.get("assets", []):
    print(asset["browser_download_url"])
PY
)
    rm -f "$json"; [[ -n "$urls" ]] || die "в релизе $RESOLVED_TAG нет файлов"
    info "релиз: $RESOLVED_TAG (все файлы берутся только из него)"
    local deb ov sums
    deb="$(pick "$urls" '/pve-qemu-kvm_[^/]*_amd64\.deb$')"
    ov="$(pick "$urls" '/pve-edk2-firmware-ovmf_[^/]*_all\.deb$')"
    sums="$(pick "$urls" '/SHA256SUMS$')"
    [[ -n "$deb" && -n "$ov" && -n "$sums" ]] || die "в релизе нет QEMU/OVMF/SHA256SUMS"
    rm -f "$WORKDIR"/pve-qemu-kvm_*_amd64.deb "$WORKDIR"/pve-edk2-firmware-ovmf_*_all.deb \
      "$WORKDIR/SHA256SUMS" "$WORKDIR/$CFG_KERNEL_ASSET" "${CFG_AML[@]/#/$WORKDIR/}"
    dl "$sums" "$WORKDIR/SHA256SUMS"
    dl "$deb" "$WORKDIR/$(basename "$deb")"; dl "$ov" "$WORKDIR/$(basename "$ov")"
    local a u
    for a in "${CFG_AML[@]}"; do
      u="$(pick "$urls" "/$a\$")"; [[ -n "$u" ]] || die "в релизе нет $a"
      dl "$u" "$WORKDIR/$a"
    done
    if [[ "$MODE" == strong ]]; then
      u="$(pick "$urls" "/$CFG_KERNEL_ASSET\$")"
      [[ -n "$u" ]] || die "в релизе нет $CFG_KERNEL_ASSET"
      dl "$u" "$WORKDIR/$CFG_KERNEL_ASSET"
    fi
  else info "download=0 — проверяю готовые файлы в $WORKDIR"; fi

  local q o required
  q="$(find_one 'pve-qemu-kvm_*_amd64.deb')"; o="$(find_one 'pve-edk2-firmware-ovmf_*_all.deb')"
  required=("$(basename "$q")" "$(basename "$o")" "${CFG_AML[@]}")
  [[ "$MODE" == strong ]] && required+=("$CFG_KERNEL_ASSET")
  verify_assets "$WORKDIR" "${required[@]}" || die "проверка файлов не пройдена — установка ОТМЕНЕНА"
  ok "все обязательные файлы прошли SHA-256 проверку"
}

find_one(){ local m=( "$WORKDIR"/$1 ); [[ -e "${m[0]}" ]] || die "в $WORKDIR нет файла по маске: $1"
  [[ ${#m[@]} -eq 1 ]] || die "под маску $1 попало несколько — оставь один: ${m[*]}"; echo "${m[0]}"; }
backup_packages(){
  local dir="$WORKDIR/.backup/packages" pkg version deb pkgdir actual
  mkdir -p "$dir" || die "не удалось создать $dir"
  for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
    version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)" \
      || die "$pkg не установлен — резервная версия неизвестна"
    st_set "OLD_${pkg}_VERSION" "$version"
    if apt-mark showhold | grep -qx "$pkg"; then st_set "OLD_${pkg}_HOLD" 1
    else st_set "OLD_${pkg}_HOLD" 0; fi
    # Всегда сохраняем именно текущую версию в новый каталог: старый .deb от прошлого
    # запуска может принадлежать другой версии и не годится для отката.
    pkgdir=$(mktemp -d "$dir/${pkg}.XXXXXX") || die "не удалось создать backup-каталог"
    info "сохраняю исходный $pkg=$version"
    (cd "$pkgdir" && apt-get download "$pkg=$version") \
      || die "не удалось скачать резервный $pkg=$version — изменения не выполнялись"
    deb=$(find "$pkgdir" -maxdepth 1 -type f -name "${pkg}_*.deb" | head -1)
    [[ -n "$deb" ]] || die "apt-get download не создал резервный $pkg"
    actual=$(dpkg-deb -f "$deb" Version) || die "не удалось прочитать версию $deb"
    [[ "$actual" == "$version" ]] || die "backup $pkg имеет версию $actual вместо $version"
    st_set "OLD_${pkg}_DEB" "$deb"
  done
}

install_userspace(){
  local q o; q="$(find_one 'pve-qemu-kvm_*_amd64.deb')"; o="$(find_one 'pve-edk2-firmware-ovmf_*_all.deb')"
  echo "QEMU: $(basename "$q")"; echo "OVMF: $(basename "$o")"
  if ! confirm "Ставим пакеты?"; then info "отменено пользователем"; return 2; fi
  backup_packages
  # Фиксируем необходимость отката ДО первого изменения пакетной базы.
  st_set PKGS 1; TRANSACTION_PKGS=1
  info "устанавливаю оба пакета через apt (с разрешением зависимостей)"
  apt-get install -y --no-install-recommends "$q" "$o" \
    || die "установка пакетов не удалась — будет выполнен откат"
  local audit; audit="$(dpkg --audit)" || die "dpkg --audit не выполнен"
  [[ -z "$audit" ]] || { printf '%s\n' "$audit" >&2; die "пакетная база не в порядке — будет выполнен откат"; }
  apt-mark hold pve-qemu-kvm pve-edk2-firmware-ovmf || die "не удалось установить apt hold"
  ok "пакеты установлены и на hold (reboot не нужен)"
}

# ── CHECK ─────────────────────────────────────────────────────────────────────
do_check(){
  echo "── Состояние ──────────────────────────────────────────"
  command -v pveversion >/dev/null && echo "PVE:        $(pveversion|head -1)" || warn "pveversion нет — это нода Proxmox?"
  echo "Ядро:       $(uname -r)"
  echo "CPU:        $(cpu_vendor) / $(cpu_model)"
  echo "QEMU:       $(dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pve-qemu-kvm 2>/dev/null||echo нет)"
  echo "OVMF:       $(dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pve-edk2-firmware-ovmf 2>/dev/null||echo нет)   (hi = на hold)"
  if dpkg-query -W pve-qemu-kvm >/dev/null 2>&1; then
    qemu-system-x86_64 -cpu help 2>/dev/null | grep -qiw host-sensors && echo "host-sensors: доступно в QEMU" || echo "host-sensors: нет (стоковый QEMU)"
  fi
  mokutil --sb-state >/dev/null 2>&1 && echo "SecureBoot: $(mokutil --sb-state 2>/dev/null)" || echo "SecureBoot: неизвестно"
  if mod_is_ours; then ok "на диске наш kvm.ko (modinfo realpc=antidetect)"
  else echo "kvm.ko: на диске стоковый/без метки realpc"; fi
  [[ -d /sys/module/kvm ]] && echo "kvm: модуль сейчас загружен" || echo "kvm: модуль сейчас не загружен"
  local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}'|tr '\n' ' ')"
  [[ -n "$run" ]] && warn "Запущены ВМ: $run"
  echo "───────────────────────────────────────────────────────"
}

# ── NORMAL ─────────────────────────────────────────────────────────────────────
install_normal(){ need_root; transaction_begin
  echo "=== NORMAL (QEMU+host-sensors / OVMF / ACPI) ==="; fetch_assets
  install_userspace || { local rc=$?; [[ "$rc" == 2 ]] && { transaction_end; exit 0; }; exit "$rc"; }
  ok "Готово. Датчики включаются в ВМ через configvm (на AMD host-sensors будет отключён)."
  transaction_end
}

# ── STRONG: normal + собрать и поставить наш kvm.ko на хосте ─────────────────────
install_strong(){ need_root
  echo "=== STRONG (открытый kvm.ko, сборка на хосте) ==="
  local vend; vend="$(cpu_vendor)"; [[ "$vend" == unknown ]] && die "не понял CPU"
  ok "CPU: $vend"; [[ "$vend" == amd ]] && warn "host-sensors — только Intel; скрытие гипервызовов в kvm.ko будет работать и на AMD"
  mokutil --sb-state 2>/dev/null|grep -qi enabled && die "Secure Boot включён — самосборный модуль не загрузится. Выключи в BIOS."
  local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}'|tr '\n' ' ')"
  [[ -n "$run" ]] && die "выключи ВМ ($run) и повтори (модуль ядра общий для хоста)"
  transaction_begin

  fetch_assets; install_userspace || { local rc=$?; [[ "$rc" == 2 ]] && { transaction_end; exit 0; }; exit "$rc"; }

  warn "Сейчас соберём открытый kvm.ko ИЗ ИСХОДНИКОВ ядра на этом хосте. Это ЭКСПЕРИМЕНТАЛЬНО"
  warn "и заменяет модуль ядра. Держи возможность загрузиться в прежнее ядро."
  if ! confirm "Собрать и установить наш kvm.ko?"; then
    ok "Пропустил модуль. QEMU/OVMF уже стоят."; transaction_end; exit 0
  fi

  mkdir -p "$WORKDIR/kernel"
  # Архив входит в SHA256SUMS выбранного релиза; никаких скриптов из подвижного main.
  tar --no-same-owner -xzf "$WORKDIR/$CFG_KERNEL_ASSET" -C "$WORKDIR/kernel" \
    || die "не удалось распаковать проверенный $CFG_KERNEL_ASSET"
  for f in kvm-antidetect.py build-kvm.sh install-kvm.sh; do
    [[ -f "$WORKDIR/kernel/$f" ]] || die "в kernel-архиве нет $f"
  done
  info "сборка модуля (может занять минуты; нужны исходники ядра)…"
  KSRC="${KSRC:-}" bash "$WORKDIR/kernel/build-kvm.sh" || die "сборка kvm.ko не удалась (см. вывод выше; нужен deb-src или --ksrc PATH)"
  local rel built; rel="$(uname -r)"; built="$WORKDIR/kernel/out/kvm.ko-$rel"
  [[ -f "$built" ]] || die "не нашёл собранный $built"
  modinfo "$built" 2>/dev/null | grep -q '^realpc:' || die "в собранном модуле нет метки realpc — патч не применился?"
  ok "собрано: $built  (vermagic $(modinfo -F vermagic "$built"))"

  local K="/lib/modules/$rel/kernel/arch/x86/kvm" cur
  cur="$(ls "$K"/kvm.ko* 2>/dev/null | head -1)"; [[ -n "$cur" ]] || die "не нашёл текущий kvm.ko* в $K"
  st_set MODULE_PATH "$cur"; st_set MODULE_BACKUP "$cur.realpc-orig"; TRANSACTION_MODULE=1
  bash "$WORKDIR/kernel/install-kvm.sh" --yes || die "установка kvm.ko не удалась — будет выполнен откат"
  [[ -d /sys/module/kvm ]] || die "kvm не загружен после установки — будет выполнен откат"
  ok "STRONG готово. Дальше: --mode configvm --vmid N"
  transaction_end
}

# ── CONFIGVM ─────────────────────────────────────────────────────────────────
configvm(){ need_root
  [[ -n "$VMID" ]] || die "укажи --vmid N"
  local conf="/etc/pve/qemu-server/${VMID}.conf"; [[ -f "$conf" ]] || die "нет $conf (создай ВМ сначала)"
  local a
  for a in "${CFG_AML[@]}"; do [[ -f "$WORKDIR/$a" ]] || die "нет $WORKDIR/$a — сначала выполни normal/strong"; done
  verify_assets "$WORKDIR" "${CFG_AML[@]}" || die "ACPI-файлы не прошли SHA-256 проверку"
  if grep -q '^args:' "$conf" && [[ "$YES" != 1 ]]; then
    confirm "Существующая строка args: будет ПОЛНОСТЬЮ заменена. Продолжить?" || { info "отменено"; exit 0; }
  fi
  transaction_begin; TRANSACTION_VMID="$VMID"
  mkdir -p "$WORKDIR/.bak" || die "не удалось создать каталог backup"
  local bak; bak=$(mktemp "$WORKDIR/.bak/${VMID}.conf.XXXXXX") || die "не удалось создать backup"
  cp -a "$conf" "$bak" || die "не удалось сохранить исходный $conf"
  local ids; ids="$(st_get CONF_VMS)"
  [[ " $ids " == *" $VMID "* ]] || st_set CONF_VMS "$ids $VMID"
  st_set "CONF_PATH_$VMID" "$conf"; st_set "CONF_BAK_$VMID" "$bak"; ok "бэкап конфига → $bak"
  local model; model="${CPU_MODEL:-$(cpu_model)}"
  local args="${CFG_ARGS_TEMPLATE//__AML__/$WORKDIR}"; args="${args//__CPUMODEL__/$model}"
  if [[ "$(cpu_vendor)" != intel ]]; then
    args="${args//,host-sensors=on/}"
    info "host-sensors отключён: поддерживается только на Intel-хостах"
  fi
  sed '/^args:/d' "$conf" >"$conf.tmp" || die "не удалось подготовить $conf"
  echo "args: $args" >>"$conf.tmp" || die "не удалось записать $conf.tmp"
  mv "$conf.tmp" "$conf" || die "не удалось записать $conf"
  ok "args вписан в ВМ $VMID (CPU: $model)"
  if [[ -n "${CFG_VM_SET// }" ]]; then
    info "qm set $VMID $CFG_VM_SET"; qm set "$VMID" $CFG_VM_SET >/dev/null \
      || die "qm set не прошёл — конфигурация будет восстановлена"
    ok "железо ВМ: $CFG_VM_SET"
  fi
  info "Общий MAC-prefix кластера не изменяю; MAC задаётся отдельно в net0 каждой ВМ."
  ok "Готово. Запусти ВМ и проверь датчики в HWiNFO/AIDA64."
  transaction_end
}

# Тесты могут загружать функции без выполнения check/изменений на хосте.
[[ "${REALPC_SETUP_SOURCE_ONLY:-0}" == 1 ]] && return 0

do_check; echo
case "$MODE" in
  check)    : ;;
  normal)   install_normal ;;
  strong)   install_strong ;;
  configvm) configvm ;;
  rollback) need_root; rollback ;;
  *) die "режим: check|normal|strong|configvm|rollback" ;;
esac

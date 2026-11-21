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
CFG_MAC_PREFIX="D8:FC:93"                 # префикс MAC (configvm, при наличии pvesh)

# .aml, которые раскладываем и подключаем (берутся из АССЕТОВ релиза, не из main)
CFG_AML=(ssdt.aml ssdt-ec.aml hpet.aml)

# Шаблон args. __AML__ -> путь к папке .aml, __CPUMODEL__ -> модель CPU.
# ВАЖНО: host-sensors=on включает проброс датчиков хоста (наша открытая реализация, Intel).
CFG_ARGS_TEMPLATE='-acpitable file=__AML__/ssdt.aml -acpitable file=__AML__/ssdt-ec.aml -acpitable file=__AML__/hpet.aml -cpu host,host-cache-info=on,hypervisor=off,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true,host-sensors=on -smbios type=0,vendor="American Megatrends International LLC.",version=H3.7G,date=02/21/2023,release=3.7 -smbios type=1,manufacturer="Maxsun",product="MS-Terminator B760M",version="VER:H3.7G" -smbios type=2,manufacturer="Maxsun",product="MS-Terminator B760M",version="VER:H3.7G" -smbios type=3,manufacturer="Default string",version="Default string" -smbios type=17,serial=66666666,asset=9876543210 -smbios type=4,manufacturer="Intel(R) Corporation",version="__CPUMODEL__" -smbios type=9 -smbios type=8'

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

[[ -z "$LOGFILE" ]] && LOGFILE="$SELF_DIR/$SELF_NAME.log"

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
st_set(){ mkdir -p "$WORKDIR"; grep -v "^$1=" "$STATE" 2>/dev/null >"$STATE.tmp" || true
          echo "$1=$2" >>"$STATE.tmp"; mv "$STATE.tmp" "$STATE"; dbg "state $1=$2"; }
st_get(){ [[ -f "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | tail -1; }

rollback(){
  trap - ERR
  warn "ОТКАТ изменений…"
  local mb mp; mb="$(st_get MODULE_BACKUP)"; mp="$(st_get MODULE_PATH)"
  if [[ -n "$mb" && -f "$mb" && -n "$mp" ]]; then
    local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}')"
    if [[ -z "$run" ]]; then
      rmmod kvm_intel 2>/dev/null||true; rmmod kvm_amd 2>/dev/null||true; rmmod kvm 2>/dev/null||true
      cp -f "$mb" "$mp" && depmod "$(uname -r)" 2>/dev/null||true
      modprobe "kvm_$(cpu_vendor)" 2>/dev/null||true
      ok "kvm.ko восстановлен из $mb"
    else warn "ВМ запущены — верну модуль при откате без запущенных ВМ."; fi
  fi
  if [[ "$(st_get PKGS)" == "1" ]]; then
    apt-mark unhold pve-qemu-kvm pve-edk2-firmware-ovmf 2>/dev/null||true
    if confirm "Переустановить стоковые QEMU/OVMF из репозитория Proxmox?"; then
      apt reinstall -y pve-qemu-kvm pve-edk2-firmware-ovmf || warn "apt reinstall не прошёл — сделай вручную при сети."
    fi
  fi
  local cb; cb="$(st_get CONF_BAK)"
  if [[ -n "$cb" && -f "$cb" ]]; then
    local cf; cf="$(st_get CONF_PATH)"; [[ -n "$cf" ]] && cp -f "$cb" "$cf" && ok "Конфиг ВМ восстановлен из $cb"
  fi
  warn "Откат завершён."
}
on_err(){ local rc=$?; err "Сбой (код $rc) на строке ${BASH_LINENO[0]}."; rollback; exit "$rc"; }

# ── скачивание релиза ────────────────────────────────────────────────────────
dl(){ info "скачиваю $(basename "$2")"; curl -fSL --retry 3 -o "$2" "$1" || wget -O "$2" "$1" || die "не скачал: $1"; }
gh_urls(){ local api="https://api.github.com/repos/$REPO/releases?per_page=30"
  [[ "$RELEASE" != latest ]] && api="https://api.github.com/repos/$REPO/releases/tags/$RELEASE"
  curl -fsSL "$api" 2>/dev/null | grep -oE '"browser_download_url":[^"]*"[^"]+"' | sed -E 's/.*"(https[^"]+)"$/\1/'; }
pick(){ echo "$1" | grep -E "$2" | head -1; }  # $1 urls, $2 regex

fetch_assets(){ # качает QEMU/OVMF/.aml (+SHA256SUMS) из нашего релиза
  [[ "$DOWNLOAD" == 1 ]] || { info "download=0 — беру готовое из $WORKDIR"; return 0; }
  mkdir -p "$WORKDIR"; command -v curl >/dev/null || command -v wget >/dev/null || die "нет curl/wget"
  local urls; urls="$(gh_urls)"; [[ -n "$urls" ]] || die "не получил список релизов (сеть? репозиторий?)"
  local tag; tag="$(echo "$urls"|sed -nE '1s#.*/download/([^/]+)/.*#\1#p')"; [[ -n "$tag" ]] && info "релиз: $tag"
  local deb ov; deb="$(pick "$urls" '/pve-qemu-kvm_[^/]*_amd64\.deb$')"
  ov="$(pick "$urls" '/pve-edk2-firmware-ovmf_[^/]*_all\.deb$')"
  [[ -n "$deb" && -n "$ov" ]] || die "в релизе нет QEMU/OVMF .deb"
  dl "$deb" "$WORKDIR/$(basename "$deb")"; dl "$ov" "$WORKDIR/$(basename "$ov")"
  for a in "${CFG_AML[@]}"; do
    local u; u="$(pick "$urls" "/$a\$")"; [[ -n "$u" ]] && dl "$u" "$WORKDIR/$a" || warn "в релизе нет $a"
  done
  local sums; sums="$(pick "$urls" '/SHA256SUMS$')"
  if [[ -n "$sums" ]]; then dl "$sums" "$WORKDIR/SHA256SUMS"
    ( cd "$WORKDIR" && sha256sum -c SHA256SUMS --ignore-missing >/dev/null 2>&1 ) \
      && ok "контрольные суммы совпали" || warn "sha256 не сошлись/не проверены — смотри сам"
  fi
}

find_one(){ local m=( $WORKDIR/$1 ); [[ -e "${m[0]}" ]] || die "в $WORKDIR нет файла по маске: $1"
  [[ ${#m[@]} -eq 1 ]] || die "под маску $1 попало несколько — оставь один: ${m[*]}"; echo "${m[0]}"; }
inst_deb(){ [[ -f "$1" ]] || die "нет файла $1"; info "dpkg -i $(basename "$1")"
  dpkg -i "$1" || die "dpkg ошибка на $(basename "$1") — НЕ запускай 'apt -f install' вслепую."; }

install_userspace(){ # ставит QEMU(+host-sensors) и OVMF, держит на hold
  local q o; q="$(find_one 'pve-qemu-kvm_*_amd64.deb')"; o="$(find_one 'pve-edk2-firmware-ovmf_*_all.deb')"
  echo "QEMU: $(basename "$q")"; echo "OVMF: $(basename "$o")"
  confirm "Ставим пакеты?" || return 1
  inst_deb "$q"; inst_deb "$o"; st_set PKGS 1
  apt-mark hold pve-qemu-kvm pve-edk2-firmware-ovmf
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
  if mod_is_ours; then ok "наш kvm.ko загружен (modinfo realpc=antidetect)"
  else echo "kvm.ko: стоковый (наш модуль не загружен)"; fi
  local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}'|tr '\n' ' ')"
  [[ -n "$run" ]] && warn "Запущены ВМ: $run"
  echo "───────────────────────────────────────────────────────"
}

# ── NORMAL ─────────────────────────────────────────────────────────────────────
install_normal(){ need_root; trap on_err ERR
  echo "=== NORMAL (QEMU+host-sensors / OVMF / ACPI) ==="; fetch_assets
  install_userspace || { trap - ERR; exit 0; }
  ok "Готово. Датчики включаются в ВМ через configvm (host-sensors=on уже в шаблоне args)."
  trap - ERR
}

# ── STRONG: normal + собрать и поставить наш kvm.ko на хосте ─────────────────────
install_strong(){ need_root; trap on_err ERR
  echo "=== STRONG (открытый kvm.ko, сборка на хосте) ==="
  local vend; vend="$(cpu_vendor)"; [[ "$vend" == unknown ]] && die "не понял CPU"
  ok "CPU: $vend"; [[ "$vend" == amd ]] && warn "host-sensors — только Intel; скрытие гипервызовов в kvm.ko будет работать и на AMD"
  mokutil --sb-state 2>/dev/null|grep -qi enabled && die "Secure Boot включён — самосборный модуль не загрузится. Выключи в BIOS."
  local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}'|tr '\n' ' ')"
  [[ -n "$run" ]] && die "выключи ВМ ($run) и повтори (модуль ядра общий для хоста)"
  command -v zstd >/dev/null || { info "ставлю zstd"; apt-get install -y --no-install-recommends zstd >/dev/null; }

  fetch_assets; install_userspace || { trap - ERR; exit 0; }

  warn "Сейчас соберём открытый kvm.ko ИЗ ИСХОДНИКОВ ядра на этом хосте. Это ЭКСПЕРИМЕНТАЛЬНО"
  warn "и заменяет модуль ядра. Держи возможность загрузиться в прежнее ядро."
  confirm "Собрать и установить наш kvm.ko?" || { ok "Пропустил модуль. QEMU/OVMF уже стоят."; trap - ERR; exit 0; }

  mkdir -p "$WORKDIR/kernel"
  for f in kvm-antidetect.py build-kvm.sh install-kvm.sh; do
    dl "https://raw.githubusercontent.com/$REPO/main/kernel/$f" "$WORKDIR/kernel/$f"
  done
  chmod +x "$WORKDIR/kernel/"*.sh
  info "сборка модуля (может занять минуты; нужны исходники ядра)…"
  KSRC="${KSRC:-}" bash "$WORKDIR/kernel/build-kvm.sh" || die "сборка kvm.ko не удалась (см. вывод выше; нужен deb-src или --ksrc PATH)"
  local rel built; rel="$(uname -r)"; built="$WORKDIR/kernel/out/kvm.ko-$rel"
  [[ -f "$built" ]] || die "не нашёл собранный $built"
  modinfo "$built" 2>/dev/null | grep -q '^realpc:' || die "в собранном модуле нет метки realpc — патч не применился?"
  ok "собрано: $built  (vermagic $(modinfo -F vermagic "$built"))"

  # найти текущий модуль (учитывая сжатие .zst/.xz) и аккуратно подменить
  local K="/lib/modules/$rel/kernel/arch/x86/kvm" cur
  cur="$(ls "$K"/kvm.ko* 2>/dev/null | head -1)"; [[ -n "$cur" ]] || die "не нашёл текущий kvm.ko* в $K"
  rmmod kvm_intel 2>/dev/null||true; rmmod kvm_amd 2>/dev/null||true
  rmmod kvm 2>/dev/null || die "kvm занят — все ВМ точно выключены?"
  [[ -e "$cur.realpc-orig" ]] || { cp -a "$cur" "$cur.realpc-orig"; ok "бэкап → $(basename "$cur").realpc-orig"; }
  st_set MODULE_PATH "$cur"; st_set MODULE_BACKUP "$cur.realpc-orig"
  case "$cur" in
    *.zst) zstd -q -f -o "$cur" "$built" ;;
    *.xz)  xz -f -c "$built" > "$cur" ;;
    *)     cp -f "$built" "$cur" ;;
  esac
  depmod "$rel"; update-initramfs -u -k "$rel" >/dev/null 2>&1 || true
  modprobe "kvm_$vend"
  mod_is_ours && ok "наш kvm.ko загружен (modinfo realpc=antidetect)" \
    || die "модуль заменён, но метки realpc в загруженном kvm нет — проверь вручную"
  ok "STRONG готово. Дальше: --mode configvm --vmid N"
  trap - ERR
}

# ── CONFIGVM ─────────────────────────────────────────────────────────────────
configvm(){ need_root; trap on_err ERR
  [[ -n "$VMID" ]] || die "укажи --vmid N"
  local conf="/etc/pve/qemu-server/${VMID}.conf"; [[ -f "$conf" ]] || die "нет $conf (создай ВМ сначала)"
  for a in "${CFG_AML[@]}"; do [[ -f "$WORKDIR/$a" ]] || warn "нет $WORKDIR/$a — args сошлётся на отсутствующий файл (запусти normal/strong с download)"; done
  mkdir -p "$WORKDIR/.bak"; local bak="$WORKDIR/.bak/${VMID}.conf.$(date +%s)"
  cp -a "$conf" "$bak"; st_set CONF_PATH "$conf"; st_set CONF_BAK "$bak"; ok "бэкап конфига → $bak"
  local model; model="${CPU_MODEL:-$(cpu_model)}"
  local args="${CFG_ARGS_TEMPLATE//__AML__/$WORKDIR}"; args="${args//__CPUMODEL__/$model}"
  grep -v '^args:' "$conf" >"$conf.tmp"; echo "args: $args" >>"$conf.tmp"; mv "$conf.tmp" "$conf"
  ok "args вписан в ВМ $VMID (CPU: $model, host-sensors=on)"
  if [[ -n "${CFG_VM_SET// }" ]]; then
    info "qm set $VMID $CFG_VM_SET"; qm set "$VMID" $CFG_VM_SET >/dev/null && ok "железо ВМ: $CFG_VM_SET" || warn "qm set частично не прошёл"
  fi
  command -v pvesh >/dev/null && pvesh set /cluster/options --mac-prefix "$CFG_MAC_PREFIX" >/dev/null 2>&1 \
    && ok "MAC-префикс: $CFG_MAC_PREFIX" || true
  ok "Готово. Запусти ВМ и проверь датчики в HWiNFO/AIDA64."
  trap - ERR
}

do_check; echo
case "$MODE" in
  check)    : ;;
  normal)   install_normal ;;
  strong)   install_strong ;;
  configvm) configvm ;;
  rollback) need_root; rollback ;;
  *) die "режим: check|normal|strong|configvm|rollback" ;;
esac

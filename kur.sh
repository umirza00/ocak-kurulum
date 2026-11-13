#!/usr/bin/env bash
# Ocak kurulumu / Ocak installer
#
# Kutusundan yeni çıkmış bir Linux bilgisayarı ya da Mac'i ailenin kutusu
# yapar. Turns a fresh Linux computer or Mac into the family's box.
#
#   curl -fsSL https://raw.githubusercontent.com/<depo>/main/kur.sh | sudo bash
#
# Ne yapar / what it does:
#   1. root yetkisi, işletim sistemi ve işlemci (Linux/macOS, amd64/arm64)
#   2. Linux: gerekli paketler (şifreli disk, TPM), uyku kapatılır, saat
#      eşitlemesi, güvenlik duvarında kutunun portları
#      Mac: Docker yoksa (onayla) Docker Desktop kurulur ve açılır, uyku
#      kapatılır, elektrik gelince açılma
#   3. Ocak programları (ocak-kur, ocak-kutu) indirilir, SHA-256'ları bu
#      betikteki değerlerle karşılaştırılır, /usr/local/bin'e kurulur
#   4. Kurtarma anahtarı için USB bellek bulunur (Linux'ta gerekirse bağlanır)
#   5. ocak-kur install: sistem kontrolü, sözleşme, veri diski, servis,
#      kurtarma anahtarı, Claude girişi, ilk telefonun QR'ı
#      ya da ocak-kur restore: yedek diskinden yeni makineye geri yükleme
#   6. İsteğe bağlı yedek diski (ocak-kur backup)
#   7. USB bellek çıkarılır, kalan elle yapılacaklar yazılır
#
# Bütün betik main'in içinde ve en son satırda çağrılır: indirme yarıda
# kesilirse hiçbir şey çalışmaz. macOS'un bash 3.2'siyle çalışır.

# --- yayın: scripts/release.sh doldurur / filled in by scripts/release.sh ---
OCAK_VERSION="0.1.1"
OCAK_REPO="umirza00/ocak-kurulum"
OCAK_BASE="https://github.com/umirza00/ocak-kurulum/releases/download/v0.1.1"
OCAK_SUMS="
267db99aa26c3bfc587410a422a9065060b2b6b988396dfe170266c57dfb184b  ocak-kur-darwin-amd64
27f4710ccd8ebe0b937b4f95b0607b67937c0c31cbd5db5605113701e43193cd  ocak-kur-darwin-arm64
ff0ae3b0c8bf94036149ab810f4b9863b332747774759fd915312a918105d6dd  ocak-kur-linux-amd64
fee83ca5555d6a923a6513a5f8eb4d09cf35c86d042b25e2f0b2c6731dae9c82  ocak-kur-linux-arm64
9239abdcf415e5381037b2e83ac2c87ed018fe7a563c5e3fc713b8fa7bd7d0cf  ocak-kutu-darwin-amd64
caf491cc3f7e2871f7ad5049db9893650232ec6d822ac4ae792c2a0ec39b8ec4  ocak-kutu-darwin-arm64
075476f3f7c907194af81a40ed2c8c1505a6e7c572f52351f76c2071e18142f9  ocak-kutu-linux-amd64
b3123d9202216c472f04717c4d5675ab63a9fcd3c12dcf28c6e21499aab21767  ocak-kutu-linux-arm64
"
# --- yayın sonu ---

set -u
umask 022

BIN_DIR=/usr/local/bin
TMP=""
USB=""          # kurtarma anahtarının belleği
USB_MOUNTED=""  # biz bağladıysak (Linux) çıkarırken ayırırız
BACKUP_MOUNT=/mnt/ocak-yedek
PORTS_UDP="41641 5353"  # WireGuard + adres keşfi, mDNS
PORTS_TCP="41642"       # ev ağında eşleme

# ---------------------------------------------------------------- yardımcılar

say() { printf '%s\n' "$*"; }
step() { printf '\n\033[1m▸ %s\033[0m\n  %s\n' "$1" "$2"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() {
	printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2
	[ -n "${2:-}" ] && printf '  %s\n' "$2" >&2
	exit 1
}

cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }

# ask "soru": a line from the terminal (stdin is this script when piped).
ask() {
	local a=""
	printf '%s' "$1" >/dev/tty
	IFS= read -r a </dev/tty || true
	printf '%s' "$a"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# confirm "soru": only "evet" or "yes" go on, as in ocak-kur.
confirm() {
	case "$(lower "$(ask "$1 (evet/yes): ")")" in
	evet | yes) return 0 ;;
	esac
	return 1
}

# choose "soru" item…: prints the chosen item; empty if none.
choose() {
	local q="$1" i=1 n
	shift
	for it in "$@"; do
		printf '    %d) %s\n' "$i" "$it" >/dev/tty
		i=$((i + 1))
	done
	n="$(ask "$q")"
	case "$n" in
	'' | *[!0-9]*) return 0 ;;
	esac
	[ "$n" -ge 1 ] && [ "$n" -le $# ] || return 0
	eval "printf '%s' \"\${$n}\""
}

have() { command -v "$1" >/dev/null 2>&1; }

# fetch URL FILE
fetch() {
	if have curl; then
		curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
	elif have wget; then
		wget -q -O "$2" "$1"
	else
		return 1
	fi
}

sha256() {
	if have sha256sum; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

# ------------------------------------------------------------- başlangıç

need_terminal() {
	if ! { : </dev/tty; } 2>/dev/null; then
		die "Bu kurulum soru soruyor ama terminal yok." "Run it in a terminal (an SSH session with a TTY works: ssh -t)."
	fi
}

need_release() {
	if [ -z "$OCAK_VERSION" ] || [ -z "$OCAK_BASE" ] || [ -z "$OCAK_SUMS" ]; then
		die "Bu betik yayımlanmış bir kopya değil (sürüm bilgisi yok)." "Use the published command from the Ocak page."
	fi
}

need_root() {
	[ "$(id -u)" = 0 ] && return 0
	have sudo || die "Yönetici (root) yetkisi gerekiyor ve sudo yok." "Önce 'su -' ile root olun, sonra komutu yeniden çalıştırın."
	say "Yönetici (root) yetkisi gerekiyor; sudo ile yeniden başlatılıyor… / Restarting with sudo…"
	if [ -f "${BASH_SOURCE[0]:-}" ]; then
		exec sudo bash "${BASH_SOURCE[0]}"
	fi
	local self="https://raw.githubusercontent.com/$OCAK_REPO/main/kur.sh"
	local s
	s="$(curl -fsSL "$self" 2>/dev/null || wget -q -O - "$self")" || die "Betik yeniden indirilemedi." "$self"
	exec sudo bash -c "$s"
}

OS=""
ARCH=""
platform() {
	case "$(uname -s)" in
	Linux) OS=linux ;;
	Darwin) OS=darwin ;;
	*) die "Bu işletim sistemi desteklenmiyor: $(uname -s)" "Ocak Linux ve macOS'ta çalışır / runs on Linux and macOS." ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*) die "Bu işlemci desteklenmiyor: $(uname -m)" "Ocak amd64 (x86-64) ve arm64 işlemcilerde çalışır." ;;
	esac
}

state_dir() {
	if [ "$OS" = darwin ]; then
		printf '%s' "/Library/Application Support/Ocak"
	else
		printf '%s' /var/lib/ocak
	fi
}

already_installed() {
	[ -f "$(state_dir)/state.json" ] || return 0
	say ""
	say "Bu makinede zaten bir Ocak kutusu kurulu. / A box is already installed here."
	say "Kurulum yeniden yapılmaz. İşe yarayabilecek komutlar:"
	say "  sudo ocak-kur claude-token          Sor'un Claude girişi (yenileme)"
	say "  sudo ocak-kur backup -to <disk>     yedek diski ekleme"
	say "  sudo ocak-kur recover               kutunun kendi anahtar parçası kaybolduysa (USB bellekle)"
	exit 0
}

# ------------------------------------------------------------------- Linux

OS_ID=""
OS_NAME=""
linux_release() {
	[ -r /etc/os-release ] || return 0
	# shellcheck source=/dev/null
	OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
	OS_NAME="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$OS_ID}")"
}

linux_systemd() {
	[ -d /run/systemd/system ] || die "Bu Linux systemd ile açılmamış." "Ocak systemd ister (Ubuntu, Debian, Fedora, Arch, openSUSE)."
	local v
	v="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')"
	case "$v" in '' | *[!0-9]*) v=0 ;; esac
	if [ "$v" -lt 250 ]; then
		die "Bu Linux sürümü çok eski (systemd $v)." "Kutunun anahtar parçası TPM'de systemd-creds ile durur (systemd 250+): Ubuntu 24.04, Debian 13, Fedora 40 ya da daha yenisi."
	fi
}

# apt_pick a|b|c: the first package the archive knows.
apt_pick() {
	local p
	for p in $(printf '%s' "$1" | tr '|' ' '); do
		if apt-cache show "$p" >/dev/null 2>&1; then
			printf '%s' "$p"
			return 0
		fi
	done
}

linux_packages() {
	step "Sistem paketleri / System packages" "Şifreli veri diski (cryptsetup, ext4), diskler (util-linux), TPM kütüphaneleri (tpm2-tss), sertifikalar."
	local pkgs="" p extra="ca-certificates"
	# curl only when missing: RHEL-like systems ship curl-minimal, which
	# conflicts with the curl package.
	have curl || extra="$extra curl"
	if have apt-get; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq || warn "apt-get update başarısız; var olan listeyle devam ediliyor"
		for p in cryptsetup e2fsprogs util-linux tpm2-tools \
			"libtss2-tcti-device0t64|libtss2-tcti-device0" $extra; do
			p="$(apt_pick "$p")"
			[ -n "$p" ] && pkgs="$pkgs $p"
		done
		# shellcheck disable=SC2086
		apt-get install -y -qq --no-install-recommends $pkgs >/dev/null || die "Paketler kurulamadı:$pkgs"
	elif have dnf; then
		# shellcheck disable=SC2086
		dnf install -y -q cryptsetup e2fsprogs util-linux tpm2-tss $extra >/dev/null || die "Paketler kurulamadı (dnf)."
	elif have pacman; then
		# Arch: never a partial upgrade (-Sy without -u breaks the system).
		# shellcheck disable=SC2086
		# Again without the download sandbox if it cannot start (limited seccomp).
		# shellcheck disable=SC2086
		pacman -Syu --noconfirm --needed cryptsetup e2fsprogs util-linux tpm2-tss $extra >/dev/null 2>&1 ||
			pacman -Syu --noconfirm --needed --disable-sandbox cryptsetup e2fsprogs util-linux tpm2-tss $extra >/dev/null ||
			die "Paketler kurulamadı (pacman)."
	elif have zypper; then
		# lsblk is in util-linux-systemd; the TPM libraries are separate packages.
		# shellcheck disable=SC2086
		zypper --non-interactive install cryptsetup e2fsprogs util-linux util-linux-systemd \
			libtss2-esys0 libtss2-mu0 libtss2-rc0 libtss2-tctildr0 libtss2-tcti-device0 $extra >/dev/null ||
			warn "bazı paketler kurulamadı (zypper); sistem kontrolü eksikleri söyler"
	else
		die "Bu dağıtımın paket yöneticisi tanınmıyor ($OS_NAME)." "Elle kurun: cryptsetup, e2fsprogs, util-linux, tpm2-tss; sonra yeniden çalıştırın."
	fi
	ok "cryptsetup, ext4, util-linux, TPM kütüphaneleri"
	# Docker'ı ocak-kur kurar (dağıtımın kendi paketleri, sorarak).
}

linux_power() {
	step "Uyku / Sleep" "Kutu hiç uyumamalı: telefonlar ona her an ulaşır, yedek gece alınır."
	systemctl mask --quiet sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target 2>/dev/null || true
	mkdir -p /etc/systemd/logind.conf.d
	cat >/etc/systemd/logind.conf.d/ocak.conf <<'EOF'
# Ocak: kutu dizüstüyse kapağı kapanınca da çalışsın (yeniden açılışta geçerli).
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
	ok "uyku ve askıya alma kapatıldı"
	if have timedatectl; then
		timedatectl set-ntp true 2>/dev/null && ok "saat internetten eşitleniyor"
	fi
}

linux_firewall() {
	local p
	if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
		for p in $PORTS_UDP; do ufw allow "$p/udp" >/dev/null; done
		for p in $PORTS_TCP; do ufw allow "$p/tcp" >/dev/null; done
		ok "güvenlik duvarı (ufw): UDP $PORTS_UDP, TCP $PORTS_TCP açıldı"
	fi
	if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
		for p in $PORTS_UDP; do firewall-cmd --quiet --permanent --add-port="$p/udp"; done
		for p in $PORTS_TCP; do firewall-cmd --quiet --permanent --add-port="$p/tcp"; done
		firewall-cmd --quiet --reload
		ok "güvenlik duvarı (firewalld): UDP $PORTS_UDP, TCP $PORTS_TCP açıldı"
	fi
}

# lsblk_rows: one line per block device, KEY="value" pairs.
lsblk_rows() { lsblk -P -p -o NAME,TYPE,RM,TRAN,FSTYPE,MOUNTPOINT,LABEL,SIZE,PKNAME 2>/dev/null; }

# kv KEY ROW
kv() { printf ' %s' "$2" | sed -n "s/.* $1=\"\([^\"]*\)\".*/\1/p"; }

# usb_disks: the names of USB / removable whole disks.
usb_disks() {
	local row
	lsblk_rows | while IFS= read -r row; do
		[ "$(kv TYPE "$row")" = disk ] || continue
		if [ "$(kv TRAN "$row")" = usb ] || [ "$(kv RM "$row")" = 1 ]; then
			kv NAME "$row"
			printf '\n'
		fi
	done
}

# fs_rows usb|other: filesystems on USB disks, or on the other disks;
# never the system's own mounts, swap or encrypted volumes.
fs_rows() {
	local want="$1" usb row name parent fs mp on
	usb=" $(usb_disks | tr '\n' ' ') "
	lsblk_rows | while IFS= read -r row; do
		fs="$(kv FSTYPE "$row")"
		mp="$(kv MOUNTPOINT "$row")"
		case "$fs" in vfat | exfat | ntfs | ext4 | ext3 | ext2 | xfs | btrfs | hfsplus | apfs) ;; *) continue ;; esac
		case "$mp" in / | /boot | /boot/* | /usr | /var | /home | /srv/ocak | "[SWAP]") continue ;; esac
		name="$(kv NAME "$row")"
		parent="$(kv PKNAME "$row")"
		[ -n "$parent" ] || parent="$name"
		case "$usb" in *" $parent "*) on=usb ;; *) on=other ;; esac
		[ "$on" = "$want" ] && printf '%s\n' "$row"
	done
}

describe() {
	local row="$1" label
	label="$(kv LABEL "$row")"
	printf '%s %s %s%s' "$(kv NAME "$row")" "$(kv SIZE "$row")" "$(kv FSTYPE "$row")" "${label:+ \"$label\"}"
}

# mount_fs ROW DIR [ro]
mount_fs() {
	local dev fs opts=""
	dev="$(kv NAME "$1")"
	fs="$(kv FSTYPE "$1")"
	[ "${3:-}" = ro ] && opts="-o ro"
	mkdir -p "$2"
	if [ "$fs" = ntfs ]; then
		# shellcheck disable=SC2086
		mount -t ntfs3 $opts "$dev" "$2" 2>/dev/null || mount $opts "$dev" "$2"
	else
		# shellcheck disable=SC2086
		mount $opts "$dev" "$2"
	fi
}

# ------------------------------------------------------------------- macOS

console_user() { stat -f %Su /dev/console 2>/dev/null; }

mac_external() {
	local info
	info="$(diskutil info "$1" 2>/dev/null)" || return 1
	printf '%s' "$info" | grep -q 'Protocol: *Disk Image' && return 1
	printf '%s' "$info" | grep -Eq 'Removable Media: *Removable|Device Location: *External|Protocol: *USB'
}

# mac_volumes: external volumes, not the data volume.
mac_volumes() {
	local v
	for v in /Volumes/*; do
		[ -d "$v" ] || continue
		[ "$v" = /Volumes/OcakData ] && continue
		mac_external "$v" && printf '%s\n' "$v"
	done
}

docker_ok() { docker info >/dev/null 2>&1; }

mac_start_app() {
	local u uid
	u="$(console_user)"
	uid="$(id -u "$u" 2>/dev/null)" || return 1
	launchctl asuser "$uid" sudo -u "$u" open -a "$1"
}

mac_wait_docker() {
	local i
	printf '  Docker açılıyor; ekranda bir pencere çıkarsa onaylayın' >/dev/tty
	for i in $(seq 1 100); do
		if docker_ok; then
			printf '\n' >/dev/tty
			return 0
		fi
		printf '.' >/dev/tty
		sleep 3
	done
	printf '\n' >/dev/tty
	return 1
}

mac_docker() {
	export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
	step "Docker" "Ailenin uygulamaları (fotoğraflar, belgeler, kütüphane…) Docker konteynerlerinde çalışır."
	if docker_ok; then
		ok "Docker çalışıyor ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
		return 0
	fi
	local u
	u="$(console_user)"
	case "$u" in '' | root | loginwindow | _mbsetupuser)
		die "Mac'te bir kullanıcının oturumu açık olmalı." "Docker Desktop kullanıcı oturumunda çalışır. Mac'te oturum açın, Terminal'den yeniden çalıştırın." ;;
	esac
	if [ -d /Applications/Docker.app ]; then
		mac_start_app Docker || true
		mac_wait_docker || die "Docker Desktop açılmadı." "Docker Desktop'ı elle açın, balina simgesi durunca yeniden çalıştırın."
		ok "Docker Desktop çalışıyor"
		return 0
	fi
	if [ -d /Applications/OrbStack.app ]; then
		mac_start_app OrbStack || true
		mac_wait_docker || die "OrbStack açılmadı." "OrbStack'i elle açın, sonra yeniden çalıştırın."
		ok "OrbStack çalışıyor"
		return 0
	fi
	local major
	major="$(sw_vers -productVersion | cut -d. -f1)"
	if [ "$major" -lt 14 ]; then
		die "Docker Desktop macOS 14 (Sonoma) ya da daha yenisini istiyor; bu Mac $(sw_vers -productVersion)." "macOS'u güncelleyin ya da OrbStack/Colima kurun, sonra yeniden çalıştırın."
	fi
	say "  Docker kurulu değil. Docker Desktop indirilip kurulacak (~600 MB)."
	say "  Docker Desktop'ın lisansını siz kabul etmiş olursunuz: evde ve küçük işletmelerde ücretsiz."
	say "  https://docs.docker.com/subscription/desktop-license/"
	confirm "  Docker Desktop kurulsun mu? / Install Docker Desktop?" || die "Docker olmadan kurulum yapılamaz." "Docker Desktop, OrbStack ya da Colima kurup yeniden çalıştırın."
	local arch=amd64 dmg="$TMP/Docker.dmg" mnt="$TMP/docker-dmg"
	[ "$ARCH" = arm64 ] && arch=arm64
	say "  İndiriliyor… / Downloading…"
	fetch "https://desktop.docker.com/mac/main/$arch/Docker.dmg" "$dmg" || die "Docker Desktop indirilemedi." "İnternet bağlantısını kontrol edip yeniden çalıştırın."
	mkdir -p "$mnt"
	hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$dmg" || die "Docker Desktop disk görüntüsü açılamadı."
	# Docker Inc.'in Apple imzası: başka biri değiştirdiyse kurulmaz.
	if ! codesign --verify --strict "$mnt/Docker.app" 2>/dev/null ||
		! codesign -dv "$mnt/Docker.app" 2>&1 | grep -q 'TeamIdentifier=9BNSXJN65R'; then
		hdiutil detach -quiet "$mnt" || true
		die "Docker Desktop'ın imzası doğrulanamadı; kurulmadı."
	fi
	"$mnt/Docker.app/Contents/MacOS/install" --accept-license --user="$u" >/dev/null || {
		hdiutil detach -quiet "$mnt" || true
		die "Docker Desktop kurulamadı."
	}
	hdiutil detach -quiet "$mnt" || true
	rm -f "$dmg"
	ok "Docker Desktop kuruldu"
	mac_start_app Docker || true
	mac_wait_docker || die "Docker Desktop açılmadı." "Docker Desktop'ı elle açın, balina simgesi durunca yeniden çalıştırın."
	ok "Docker Desktop çalışıyor"
}

mac_power() {
	step "Uyku / Sleep" "Kutu hiç uyumamalı; elektrik gelince kendiliğinden açılmalı."
	pmset -c sleep 0 disksleep 0 womp 1 >/dev/null 2>&1 && ok "prizdeyken uyku kapatıldı, ağdan uyandırma açık"
	if pmset -a autorestart 1 >/dev/null 2>&1; then
		ok "elektrik kesilip gelince Mac kendiliğinden açılır"
	else
		warn "bu Mac elektrik gelince kendiliğinden açılmayı desteklemiyor (dizüstü)"
	fi
}

mac_firewall() {
	local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
	[ -x "$fw" ] || return 0
	if "$fw" --getglobalstate 2>/dev/null | grep -qi enabled; then
		"$fw" --add "$BIN_DIR/ocak-kutu" >/dev/null 2>&1 || true
		"$fw" --unblockapp "$BIN_DIR/ocak-kutu" >/dev/null 2>&1 || true
		ok "macOS güvenlik duvarı ocak-kutu'ya izin veriyor"
	fi
}

# ---------------------------------------------------------------- programlar

install_programs() {
	step "Ocak programları / Ocak programs" "Sürüm $OCAK_VERSION, $OS/$ARCH. İndirilen her dosya bu betikteki SHA-256 ile karşılaştırılır."
	local name file want got
	mkdir -p "$BIN_DIR"
	for name in ocak-kur ocak-kutu; do
		file="$name-$OS-$ARCH"
		want="$(printf '%s\n' "$OCAK_SUMS" | awk -v f="$file" '$2 == f { print $1 }')"
		[ -n "$want" ] || die "$file bu sürümde yok."
		fetch "$OCAK_BASE/$file" "$TMP/$file" || die "$file indirilemedi." "$OCAK_BASE/$file"
		got="$(sha256 "$TMP/$file")"
		[ "$got" = "$want" ] || die "$file bozuk ya da değiştirilmiş; kurulmadı." "beklenen $want, gelen $got"
		chmod 0755 "$TMP/$file"
		[ "$OS" = darwin ] && xattr -c "$TMP/$file" 2>/dev/null
		mv -f "$TMP/$file" "$BIN_DIR/$name"
		ok "$BIN_DIR/$name"
	done
}

# ---------------------------------------------------------------- USB bellek

# pick_row "soru" ROWS: lets the admin pick one lsblk row; prints it.
pick_row() {
	local rows="$2" r v
	local -a labels=()
	while IFS= read -r r; do
		[ -n "$r" ] && labels+=("$(describe "$r")")
	done <<EOF
$rows
EOF
	[ ${#labels[@]} -gt 0 ] || return 0
	if [ ${#labels[@]} -eq 1 ]; then
		v="${labels[0]}"
	else
		v="$(choose "$1" "${labels[@]}")"
	fi
	[ -n "$v" ] || return 0
	while IFS= read -r r; do
		if [ -n "$r" ] && [ "$(describe "$r")" = "$v" ]; then
			printf '%s' "$r"
			return 0
		fi
	done <<EOF
$rows
EOF
}

# pick_volume "soru" LIST: one of the newline-separated directories.
pick_volume() {
	local v
	local -a vols=()
	while IFS= read -r v; do
		[ -n "$v" ] && vols+=("$v")
	done <<EOF
$2
EOF
	[ ${#vols[@]} -gt 0 ] || return 0
	if [ ${#vols[@]} -eq 1 ]; then
		printf '%s' "${vols[0]}"
	else
		choose "$1" "${vols[@]}"
	fi
}

# find_usb new|restore: sets USB to the stick's directory.
find_usb() {
	local mode="$1" list v row i
	if [ "$mode" = new ]; then
		step "USB bellek / USB stick" "Kurtarma anahtarı bir USB belleğe yazılır (sonra kutudan silinir). Boş bir bellek takın."
	else
		step "USB bellek / USB stick" "Kurtarma anahtarının olduğu USB belleği takın (OCAK-KURTARMA-ANAHTARI.txt)."
	fi
	while :; do
		if [ "$OS" = darwin ]; then
			list="$(mac_volumes)"
			if [ "$mode" = restore ]; then
				# the stick that holds a recovery key, if there is one
				while IFS= read -r v; do
					if [ -n "$v" ] && ls "$v"/OCAK-KURTARMA-ANAHTARI*.txt >/dev/null 2>&1; then
						USB="$v"
						ok "$USB"
						return 0
					fi
				done <<EOF
$list
EOF
			fi
			USB="$(pick_volume "  Hangi bellek? / Which stick? " "$list")"
			if [ -n "$USB" ]; then
				ok "$USB"
				return 0
			fi
		else
			row="$(pick_row "  Hangi bellek? / Which stick? " "$(fs_rows usb)")"
			if [ -n "$row" ]; then
				v="$(kv MOUNTPOINT "$row")"
				if [ -z "$v" ]; then
					v=/media/ocak-usb
					mount_fs "$row" "$v" || die "Bellek bağlanamadı: $(describe "$row")"
					USB_MOUNTED="$v"
				fi
				USB="$v"
				ok "$(describe "$row") → $USB"
				return 0
			fi
		fi
		i="$(ask "  USB bellek bulunamadı ya da seçilmedi. Takın ve Enter'a basın (vazgeçmek için q): ")"
		[ "$(lower "$i")" = q ] && die "USB bellek olmadan kurulum yapılamaz."
		sleep 2
	done
}

eject_usb() {
	[ -n "$USB" ] || return 0
	sync
	if [ "$OS" = darwin ]; then
		diskutil eject "$USB" >/dev/null 2>&1 && ok "USB bellek çıkarıldı; güvenli bir yerde saklayın"
	elif [ -n "$USB_MOUNTED" ]; then
		umount "$USB_MOUNTED" 2>/dev/null && ok "USB bellek ayrıldı; çıkarıp güvenli bir yerde saklayın"
	else
		say "  USB belleği çıkarıp güvenli bir yerde saklayın."
	fi
}

# ------------------------------------------------------------- yedek diski

# find_backup: the directory of an existing backup (restore).
FROM=""
find_backup() {
	step "Yedek diski / Backup disk" "Eski kutunun yedek diskini bu makineye takın."
	local v row tmpm i
	while :; do
		if [ "$OS" = darwin ]; then
			for v in /Volumes/*/ocak-yedek.json /Volumes/*/*/ocak-yedek.json; do
				[ -f "$v" ] && {
					FROM="$(dirname "$v")"
					ok "$FROM"
					return 0
				}
			done
		else
			# already mounted somewhere
			for v in $(lsblk -nrpo MOUNTPOINT 2>/dev/null | grep -v '^$' | grep -v '^\[SWAP\]'); do
				for i in "$v"/ocak-yedek.json "$v"/*/ocak-yedek.json; do
					[ -f "$i" ] && {
						FROM="$(dirname "$i")"
						ok "$FROM"
						return 0
					}
				done
			done
			# not mounted: look inside each one read-only
			tmpm="$TMP/probe"
			while IFS= read -r row; do
				[ -n "$row" ] || continue
				[ -z "$(kv MOUNTPOINT "$row")" ] || continue
				mount_fs "$row" "$tmpm" ro 2>/dev/null || continue
				for i in "$tmpm"/ocak-yedek.json "$tmpm"/*/ocak-yedek.json; do
					if [ -f "$i" ]; then
						v="${i#"$tmpm"}"
						umount "$tmpm"
						mount_fs "$row" "$BACKUP_MOUNT" || die "Yedek diski bağlanamadı: $(describe "$row")"
						FROM="$BACKUP_MOUNT$(dirname "$v")"
						FROM="${FROM%/.}"
						ok "$(describe "$row") → $FROM"
						return 0
					fi
				done
				umount "$tmpm" 2>/dev/null
			done <<EOF
$(fs_rows usb; fs_rows other)
EOF
		fi
		i="$(ask "  Yedek bulunamadı (ocak-yedek.json). Diski takın ve Enter'a basın (vazgeçmek için q): ")"
		[ "$(lower "$i")" = q ] && die "Yedek diski olmadan geri yükleme yapılamaz."
		sleep 2
	done
}

# offer_backup: a backup disk for the new box (can be added later too).
offer_backup() {
	step "Yedek diski (isteğe bağlı) / Backup disk (optional)" "Kutu her gün şifreli yedeği bu diske alır. Yedek yalnızca kurtarma anahtarıyla açılır."
	confirm "  Şimdi bir yedek diski bağlansın mı? / Set up a backup disk now?" || {
		say "  Sonra: sudo ocak-kur backup -to <disk dizini>"
		return 0
	}
	local v row dir="" i rows
	while :; do
		if [ "$OS" = darwin ]; then
			v="$(pick_volume "  Hangi disk? / Which disk? " "$(mac_volumes | grep -vxF "$USB")")"
			if [ -n "$v" ]; then
				dir="$v/Ocak-Yedek"
				break
			fi
		else
			# every filesystem but the recovery stick
			rows="$(
				{
					fs_rows usb
					fs_rows other
				} | while IFS= read -r v; do
					[ "$(kv MOUNTPOINT "$v")" = "$USB" ] || printf '%s\n' "$v"
				done
			)"
			row="$(pick_row "  Hangi disk? / Which disk? " "$rows")"
			if [ -n "$row" ]; then
				v="$(kv MOUNTPOINT "$row")"
				if [ -z "$v" ]; then
					v="$BACKUP_MOUNT"
					mount_fs "$row" "$v" || die "Disk bağlanamadı: $(describe "$row")"
				fi
				dir="$v/Ocak-Yedek"
				break
			fi
		fi
		i="$(ask "  Disk bulunamadı ya da seçilmedi. Diski takıp Enter'a basın (atlamak için q): ")"
		if [ "$(lower "$i")" = q ]; then
			say "  Sonra: sudo ocak-kur backup -to <disk dizini>"
			return 0
		fi
		sleep 2
	done
	mkdir -p "$dir"
	"$BIN_DIR/ocak-kur" backup -to "$dir" </dev/tty || warn "Yedek diski ayarlanamadı. Sonra: sudo ocak-kur backup -to \"$dir\""
}

# -------------------------------------------------------------------- akış

finish_notes() {
	say ""
	say "Bilmeniz gerekenler / Good to know:"
	if [ "$OS" = linux ]; then
		say "  • Elektrik kesilip gelince bilgisayarın kendiliğinden açılması için BIOS/UEFI'de"
		say "    \"Restore on AC Power Loss\" (ya da \"After Power Failure\") → \"Power On\" seçin."
		say "    Kutu açılınca telefonlar evdeyse kilidini kendiliğinden açar."
	else
		say "  • Docker Desktop kullanıcı oturumunda çalışır. Mac yeniden başlarsa uygulamalar"
		say "    ($(console_user)) oturum açılınca gelir; Docker Desktop'ın ayarlarında"
		say "    \"Start Docker Desktop when you sign in\" açık kalmalı."
	fi
	say "  • Claude'u sonra bağlamak ya da tokenı yenilemek: sudo ocak-kur claude-token"
	say "  • Yedek diski eklemek: sudo ocak-kur backup -to <disk dizini>"
	say "  • Kayıtlar: $(state_dir)/kutu.log"
}

main() {
	trap cleanup EXIT
	need_terminal
	need_release
	need_root
	platform
	TMP="$(mktemp -d "${TMPDIR:-/tmp}/ocak-kur.XXXXXX")" || die "Geçici dizin açılamadı."

	say ""
	say "Ocak kurulumu $OCAK_VERSION / Ocak installer — $OS/$ARCH"
	already_installed

	say ""
	say "Bu bilgisayar ailenin kutusu olacak. Sırayla:"
	if [ "$OS" = linux ]; then
		say "  • gerekli sistem paketleri kurulur, uyku kapatılır, güvenlik duvarında kutunun portları açılır"
	else
		say "  • Docker yoksa Docker Desktop kurulur (sorulur), uyku kapatılır"
	fi
	say "  • Ocak programları indirilir ve doğrulanır"
	say "  • sistem kontrolü, kullanım sözleşmesi, USB bellek, şifreli veri diski, kurtarma anahtarı"
	say "  • Sor için Claude girişi, ilk telefonun eşlenmesi (yönetici)"
	say "  • isteğe bağlı yedek diski"
	say "This computer becomes the family's box: system packages, Docker, the Ocak programs,"
	say "terms, USB stick, encrypted data disk, recovery key, Claude, first phone, backup disk."
	say ""
	local mode
	mode="$(choose "  Seçim / Choice (1/2): " \
		"Yeni kutu kur / Set up a new box" \
		"Yedekten geri yükle: bu makine eski kutunun yerine geçiyor / Restore from a backup disk")"
	case "$mode" in
	Yeni*) mode=new ;;
	Yedek*) mode=restore ;;
	*) die "Seçim yapılmadı." ;;
	esac

	if [ "$OS" = linux ]; then
		linux_release
		say ""
		say "Sistem: $OS_NAME"
		linux_systemd
		linux_packages
		linux_power
		linux_firewall
	else
		say ""
		say "Sistem: macOS $(sw_vers -productVersion)"
		mac_docker
		mac_power
	fi

	install_programs
	[ "$OS" = darwin ] && mac_firewall

	find_usb "$mode"

	if [ "$mode" = new ]; then
		local name=""
		while [ -z "$name" ]; do
			name="$(ask "
Yöneticinin adı, telefonda görünür (ör. Umut) / Admin's name: ")"
		done
		step "Kurulum / Installation" "ocak-kur install: sistem kontrolü, sözleşme, veri diski, kurtarma anahtarı, Claude, ilk telefon."
		"$BIN_DIR/ocak-kur" install -name "$name" -usb "$USB" </dev/tty ||
			die "Kurulum tamamlanmadı." "Sorunu giderip aynı komutu yeniden çalıştırın; yarım kalan kurulum yeniden yapılabilir."
		offer_backup
	else
		find_backup
		step "Geri yükleme / Restore" "ocak-kur restore: yedek açılır, veri diski yeniden oluşturulur, kutu yeni donanımda başlar."
		"$BIN_DIR/ocak-kur" restore -from "$FROM" -usb "$USB" </dev/tty ||
			die "Geri yükleme tamamlanmadı." "Sorunu giderip aynı komutu yeniden çalıştırın."
	fi

	eject_usb
	finish_notes
	say ""
	say "✓ Ocak hazır. / Ocak is ready."
}

main "$@"

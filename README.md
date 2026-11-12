# Ocak kurulumu

Ocak, ailenin verisini kendi evindeki bir bilgisayarda tutan bir kutu ve iPhone uygulamasıdır. Bu depo yalnızca kurulum betiğini ve kutunun programlarını (sürümler sayfasında) içerir.

## Kurulum

Kutu olacak bilgisayarda bir terminal açın ve şunu çalıştırın:

```
curl -fsSL https://raw.githubusercontent.com/umirza00/ocak-kurulum/main/kur.sh | sudo bash
```

Betik her adımı Türkçe ve İngilizce anlatır, önemli adımlarda onay ister.

**Gerekenler**

- Linux (Ubuntu 24.04, Debian 13, Fedora 40 ya da daha yenisi; TPM 2.0 açık) ya da macOS 14 ve sonrası
- amd64 ya da arm64 işlemci, en az 6 çekirdek (12 önerilir), 8 GB bellek (16 önerilir), 100 GB boş yer
- Kurtarma anahtarı için boş bir USB bellek
- İsteğe bağlı: yedek diski
- Yönetici olacak kişinin iPhone'unda Ocak uygulaması

**Betik ne yapar**

1. Sistemi tanır, gerekli paketleri kurar (Linux), Docker yoksa kurar (Linux'ta dağıtımın paketleri, Mac'te onayınızla Docker Desktop), uykuyu kapatır.
2. Kutunun programlarını indirir ve her dosyayı betiğin içindeki SHA-256 ile doğrular.
3. Sistem kontrolü, kullanım sözleşmesi, USB bellek, şifreli veri diski, kurtarma anahtarı, Sor için Claude girişi ve ilk telefonun eşlenmesi.
4. İsteğe bağlı yedek diski.

Eski kutunun yerine yeni bir makine kuruyorsanız betik "Yedekten geri yükle"yi sorar: yedek diski ve kurtarma anahtarının olduğu USB bellek gerekir.

---

# Ocak installer

Ocak is a box that keeps the family's data on a computer at home, plus an iPhone app. This repository holds only the installer and the box programs (see Releases).

On the computer that becomes the box, open a terminal and run:

```
curl -fsSL https://raw.githubusercontent.com/umirza00/ocak-kurulum/main/kur.sh | sudo bash
```

Needs Linux (Ubuntu 24.04, Debian 13, Fedora 40 or newer, TPM 2.0 on) or macOS 14+, amd64 or arm64 with at least 6 cores, 8 GB RAM and 100 GB free, an empty USB stick for the recovery key and the Ocak app on the admin's iPhone. Every download is checked against the SHA-256 written in the script.
